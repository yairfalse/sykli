defmodule Sykli.Services.CacheService do
  @moduledoc """
  Service for cache operations during task execution.

  This service encapsulates cache check/restore/store logic,
  providing a clean interface for the Executor.
  """

  alias Sykli.Cache

  @type cache_result ::
          {:hit, key :: String.t()}
          | {:miss, key :: String.t(), reason :: atom()}

  @doc """
  Check cache and restore outputs if available.

  Returns:
    - `{:hit, key}` - Cache hit, outputs restored
    - `{:miss, key, reason}` - Cache miss with reason
  """
  @spec check_and_restore(Sykli.Graph.Task.t(), String.t()) :: cache_result()
  def check_and_restore(task, workdir) do
    case Cache.check_detailed(task, workdir) do
      {:hit, key} ->
        case Cache.restore(key, workdir) do
          :ok -> {:hit, key}
          {:error, _} -> {:miss, key, :restore_failed}
        end

      {:miss, key, reason} ->
        {:miss, key, reason}
    end
  end

  @doc """
  Store task outputs in cache after successful execution.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec store_result(
          String.t() | nil,
          Sykli.Graph.Task.t(),
          [String.t()],
          non_neg_integer(),
          String.t()
        ) :: :ok | {:error, term()}
  def store_result(nil, _task, _outputs, _duration_ms, _workdir), do: :ok

  def store_result(cache_key, task, outputs, duration_ms, workdir) do
    Cache.store(cache_key, task, outputs || [], duration_ms, workdir)
  end

  @doc """
  Format a cache miss reason for display.
  """
  @spec format_miss_reason(atom()) :: String.t()
  defdelegate format_miss_reason(reason), to: Cache
end
