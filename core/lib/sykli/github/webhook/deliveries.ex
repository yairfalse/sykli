defmodule Sykli.GitHub.Webhook.Deliveries do
  @moduledoc "ETS-backed replay protection for GitHub delivery IDs."

  @table :sykli_github_webhook_deliveries
  @default_limit 10_000
  @default_ttl_ms 86_400_000

  def accept(delivery_id, now_ms, opts \\ [])

  def accept(nil, _now_ms, _opts), do: {:error, :missing_delivery_id}
  def accept("", _now_ms, _opts), do: {:error, :missing_delivery_id}

  def accept(delivery_id, now_ms, opts) when is_binary(delivery_id) do
    ensure_table()
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    limit = Keyword.get(opts, :limit, @default_limit)
    prune(now_ms, ttl_ms)

    case :ets.insert_new(@table, {delivery_id, now_ms}) do
      true ->
        trim(limit)
        :ok

      false ->
        {:error, :duplicate_delivery}
    end
  end

  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Removes a delivery_id from the replay cache.

  Used by the receiver to release a cache entry when downstream processing
  failed after `accept/3` already inserted it, so GitHub's automatic retry
  for the same delivery_id can succeed instead of hitting `:duplicate_delivery`.

  Idempotent: deleting a missing key is a no-op.
  """
  def evict(delivery_id) when is_binary(delivery_id) do
    ensure_table()
    :ets.delete(@table, delivery_id)
    :ok
  end

  def evict(_other), do: :ok

  defp prune(now_ms, ttl_ms) do
    threshold = now_ms - ttl_ms

    @table
    |> :ets.tab2list()
    |> Enum.each(fn
      {id, inserted_at} when inserted_at < threshold -> :ets.delete(@table, id)
      _ -> :ok
    end)
  end

  defp trim(limit) do
    entries = :ets.tab2list(@table)
    overflow = length(entries) - limit

    if overflow > 0 do
      entries
      |> Enum.sort_by(fn {_id, inserted_at} -> inserted_at end)
      |> Enum.take(overflow)
      |> Enum.each(fn {id, _inserted_at} -> :ets.delete(@table, id) end)
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        @table
    end
  rescue
    ArgumentError -> @table
  end
end
