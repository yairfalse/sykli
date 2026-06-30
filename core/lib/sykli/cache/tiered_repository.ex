defmodule Sykli.Cache.TieredRepository do
  @moduledoc """
  Write-through tiered cache: local L1 + S3 L2.

  Reads check L1 first, then L2. Writes go to L1 synchronously
  and L2 asynchronously (never blocks the executor).

  Includes a circuit breaker for L2: after `@failure_threshold`
  consecutive S3 failures, L2 writes are skipped for a cooldown
  window. This prevents cascading timeouts when S3 is unreachable.
  """

  @behaviour Sykli.Cache.Repository

  require Logger

  alias Sykli.Cache.Entry
  alias Sykli.Cache.FileRepository, as: L1
  alias Sykli.Cache.S3Repository, as: L2

  # Circuit breaker settings
  @circuit_table :sykli_s3_circuit
  @failure_threshold 5
  @cooldown_ms 60_000

  @impl true
  def init do
    L1.init()
    L2.init()
    ensure_circuit_table()
    reset_circuit_state()
  end

  @impl true
  def get(key) do
    case L1.get(key) do
      {:ok, entry} ->
        {:ok, entry}

      {:error, _} ->
        if circuit_closed?() do
          case L2.get(key) do
            {:ok, entry} ->
              record_success()
              # Promote to L1
              L1.put(key, entry)
              {:ok, entry}

            error ->
              record_failure()
              error
          end
        else
          {:error, :s3_circuit_open}
        end
    end
  end

  @impl true
  def put(key, %Entry{} = entry) do
    L1.put(key, entry)
    async_l2(fn -> L2.put(key, entry) end)
  end

  @impl true
  def delete(key) do
    L1.delete(key)
    async_l2(fn -> L2.delete(key) end)
    :ok
  end

  @impl true
  def exists?(key) do
    L1.exists?(key) or (circuit_closed?() and L2.exists?(key))
  end

  @impl true
  def list_keys do
    local_keys = L1.list_keys() |> MapSet.new()

    remote_keys =
      if circuit_closed?() do
        L2.list_keys() |> MapSet.new()
      else
        MapSet.new()
      end

    MapSet.union(local_keys, remote_keys) |> MapSet.to_list()
  end

  @impl true
  def store_blob(content) do
    case L1.store_blob(content) do
      {:ok, hash} ->
        async_l2(fn -> L2.store_blob(content) end)
        {:ok, hash}

      error ->
        error
    end
  end

  @impl true
  def get_blob(hash) do
    case L1.get_blob(hash) do
      {:ok, content} ->
        {:ok, content}

      {:error, _} ->
        if circuit_closed?() do
          case L2.get_blob(hash) do
            {:ok, content} ->
              record_success()
              L1.store_blob(content)
              {:ok, content}

            error ->
              record_failure()
              error
          end
        else
          {:error, :s3_circuit_open}
        end
    end
  end

  @impl true
  def blob_exists?(hash) do
    L1.blob_exists?(hash) or (circuit_closed?() and L2.blob_exists?(hash))
  end

  @impl true
  def stats, do: L1.stats()

  @impl true
  def clean do
    L1.clean()
    async_l2(fn -> L2.clean() end)
    :ok
  end

  @impl true
  def clean_older_than(seconds) do
    L1.clean_older_than(seconds)
  end

  # ----- ASYNC L2 WRITES -----

  defp async_l2(fun) do
    if circuit_closed?() do
      # Fire-and-forget: start_child (not async_nolink) so the caller's mailbox
      # never accumulates unconsumed {ref, result}/{:DOWN, ...} reply messages.
      Task.Supervisor.start_child(Sykli.TaskSupervisor, fn ->
        try do
          fun.()
          record_success()
        rescue
          e ->
            record_failure()
            Logger.warning("[TieredCache] S3 write failed: #{inspect(e)}")
        end
      end)
    end

    :ok
  end

  # ----- CIRCUIT BREAKER -----

  @doc false
  def ensure_circuit_table do
    case :ets.whereis(@circuit_table) do
      :undefined ->
        try do
          :ets.new(@circuit_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

          reset_circuit_state()
        rescue
          ArgumentError ->
            seed_circuit_table()
        end

      _table ->
        # Already created (and seeded on creation) — no per-call work. This runs
        # on the cache hot path via circuit_closed?/record_*, so keep it to a
        # single :ets.whereis. Missing rows still read as 0 via circuit_value/2.
        :ok
    end

    :ok
  end

  defp circuit_closed? do
    ensure_circuit_table()
    failures = circuit_value(:failures, 0)
    open_until = circuit_value(:open_until, 0)

    cond do
      failures < @failure_threshold -> true
      now_ms() >= open_until -> true
      true -> false
    end
  end

  defp record_success do
    ensure_circuit_table()
    failures = circuit_value(:failures, 0)

    if failures > 0 do
      if failures >= @failure_threshold do
        Logger.info("[TieredCache] S3 circuit breaker closed (recovered)")
      end

      reset_circuit_state()
    end
  end

  defp record_failure do
    ensure_circuit_table()

    new_failures =
      :ets.update_counter(@circuit_table, :failures, {2, 1}, {:failures, 0})

    cond do
      new_failures == @failure_threshold ->
        open_until = now_ms() + cooldown_ms()

        :ets.insert(@circuit_table, {:open_until, open_until})

        Logger.warning(
          "[TieredCache] S3 circuit breaker OPEN after #{new_failures} consecutive failures " <>
            "(cooldown: #{cooldown_ms()}ms)"
        )

      new_failures > @failure_threshold and circuit_value(:open_until, 0) != 0 ->
        # Once the threshold-crossing failure has armed the breaker, later
        # failures are either in-flight operations from the open window or
        # failed half-open probes. Both extend/re-arm the cooldown without
        # emitting a second OPEN warning.
        :ets.insert(@circuit_table, {:open_until, now_ms() + cooldown_ms()})

      true ->
        :ok
    end
  end

  defp reset_circuit_state do
    :ets.insert(@circuit_table, [{:failures, 0}, {:open_until, 0}])
  end

  defp seed_circuit_table do
    :ets.insert_new(@circuit_table, {:failures, 0})
    :ets.insert_new(@circuit_table, {:open_until, 0})
  end

  defp circuit_value(key, default) do
    case :ets.lookup(@circuit_table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp cooldown_ms do
    Application.get_env(:sykli, :s3_circuit_cooldown_ms, @cooldown_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  if Mix.env() == :test do
    @doc false
    def __circuit_closed?, do: circuit_closed?()

    @doc false
    def __record_success__, do: record_success()

    @doc false
    def __record_failure__, do: record_failure()

    @doc false
    def __circuit_state__ do
      ensure_circuit_table()

      %{
        failures: circuit_value(:failures, 0),
        open_until: circuit_value(:open_until, 0)
      }
    end

    @doc false
    def __reset_circuit__, do: reset_circuit_state()
  end
end
