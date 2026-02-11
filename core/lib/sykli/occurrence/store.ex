defmodule Sykli.Occurrence.Store do
  @moduledoc """
  BEAM-native occurrence store — ETS for hot reads, ETF for warm persistence.

  Stores the last N occurrences in an ETS `:ordered_set` keyed by
  `{timestamp, id}` for chronological access without sorting.

  ## Access patterns

      Hot:  Store.get_latest()         # direct ETS read, no GenServer
      Warm: Store.hydrate(dir)         # load .etf files into ETS on startup
      Cold: File.read("occurrence.json") # always available

  ## Design

  - Client reads go directly to ETS (`:public, read_concurrency: true`)
  - Writes go through GenServer to serialize eviction logic
  - Follows the `RunRegistry` pattern from this codebase
  """

  use GenServer

  require Logger

  @table :sykli_occurrences
  @max_entries 50

  # ─────────────────────────────────────────────────────────────────────────────
  # CLIENT API — Direct ETS reads (no GenServer bottleneck)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Returns the most recent occurrence, or `nil` if the store is empty.
  """
  @spec get_latest() :: map() | nil
  def get_latest do
    case :ets.last(@table) do
      :"$end_of_table" -> nil
      key -> lookup(key)
    end
  end

  @doc """
  Returns an occurrence by its id, or `nil` if not found.
  """
  @spec get(String.t()) :: map() | nil
  def get(id) do
    case :ets.match_object(@table, {:_, %{"id" => id}}) do
      [{_key, occurrence}] -> occurrence
      _ -> nil
    end
  end

  @doc """
  Lists occurrences in reverse chronological order (newest first).

  ## Options

    * `:limit` — max entries to return (default: 20)
    * `:status` — filter by outcome: `"passed"` or `"failed"`
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    status = Keyword.get(opts, :status)

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, occ} -> occ end)
    |> Enum.reverse()
    |> filter_by_status(status)
    |> Enum.take(limit)
  end

  @doc """
  Returns recent outcomes for a specific task across stored occurrences.

  Returns a list of outcome strings like `["pass", "pass", "fail", "pass"]`,
  newest first.
  """
  @spec recent_outcomes(String.t(), pos_integer()) :: [String.t()]
  def recent_outcomes(task_name, n \\ 10) do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, occ} -> occ end)
    |> Enum.reverse()
    |> Enum.flat_map(fn occ ->
      case find_task_outcome(occ, task_name) do
        nil -> []
        outcome -> [outcome]
      end
    end)
    |> Enum.take(n)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CLIENT API — Writes go through GenServer
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Stores an occurrence. Evicts oldest entries if over the max.
  """
  @spec put(map()) :: :ok
  def put(occurrence) do
    GenServer.call(__MODULE__, {:put, occurrence})
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # LIFECYCLE
  # ─────────────────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :ordered_set,
        :public,
        read_concurrency: true
      ])

    # Hydrate from .etf files if a directory is provided
    workdir = Keyword.get(opts, :workdir)

    if workdir do
      hydrate_from_disk(workdir)
    end

    {:ok, %{table: table}}
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SERVER CALLBACKS
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:put, occurrence}, _from, state) do
    key = make_key(occurrence)
    :ets.insert(@table, {key, occurrence})
    evict_oldest()
    {:reply, :ok, state}
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HYDRATION — Load .etf files into ETS on startup
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Loads occurrences from `.sykli/occurrences/*.etf` into ETS.
  """
  @spec hydrate_from_disk(String.t()) :: :ok
  def hydrate_from_disk(workdir) do
    etf_dir = Path.join([workdir, ".sykli", "occurrences"])

    case File.ls(etf_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".etf"))
        |> Enum.sort()
        |> Enum.take(-@max_entries)
        |> Enum.each(fn filename ->
          path = Path.join(etf_dir, filename)

          case File.read(path) do
            {:ok, binary} ->
              occurrence = :erlang.binary_to_term(binary)
              key = make_key(occurrence)
              :ets.insert(@table, {key, occurrence})

            {:error, reason} ->
              Logger.warning("[Occurrence.Store] Failed to load #{filename}: #{inspect(reason)}")
          end
        end)

        evict_oldest()

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Occurrence.Store] Failed to read ETF directory: #{inspect(reason)}")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # PRIVATE
  # ─────────────────────────────────────────────────────────────────────────────

  defp make_key(occurrence) do
    timestamp = occurrence["timestamp"] || DateTime.to_iso8601(DateTime.utc_now())
    id = occurrence["id"] || "unknown"
    {timestamp, id}
  end

  defp evict_oldest do
    size = :ets.info(@table, :size)

    if size > @max_entries do
      # Delete oldest entries (smallest keys in ordered_set)
      to_remove = size - @max_entries

      Enum.reduce_while(1..to_remove, :ets.first(@table), fn _, key ->
        case key do
          :"$end_of_table" ->
            {:halt, :"$end_of_table"}

          key ->
            next = :ets.next(@table, key)
            :ets.delete(@table, key)
            {:cont, next}
        end
      end)
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, occurrence}] -> occurrence
      [] -> nil
    end
  end

  defp filter_by_status(occurrences, nil), do: occurrences

  defp filter_by_status(occurrences, status) do
    Enum.filter(occurrences, &(&1["outcome"] == status))
  end

  defp find_task_outcome(occurrence, task_name) do
    tasks = get_in(occurrence, ["ci_data", "tasks"]) || []

    case Enum.find(tasks, &(&1["name"] == task_name)) do
      %{"status" => status} -> normalize_outcome(status)
      _ -> nil
    end
  end

  defp normalize_outcome("passed"), do: "pass"
  defp normalize_outcome("cached"), do: "pass"
  defp normalize_outcome("failed"), do: "fail"
  defp normalize_outcome("skipped"), do: "skip"
  defp normalize_outcome("blocked"), do: "skip"
  defp normalize_outcome(other), do: other
end
