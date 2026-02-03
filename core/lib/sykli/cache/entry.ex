defmodule Sykli.Cache.Entry do
  @moduledoc """
  Domain entity representing a cache entry.

  A cache entry contains metadata about a cached task result,
  including the command, outputs, timing, and version information.
  """

  @type output :: %{
          path: String.t(),
          blob: String.t(),
          mode: non_neg_integer(),
          size: non_neg_integer()
        }

  @type t :: %__MODULE__{
          task_name: String.t(),
          command: String.t(),
          outputs: [output()],
          duration_ms: non_neg_integer(),
          cached_at: DateTime.t(),
          inputs_hash: String.t(),
          container: String.t(),
          env_hash: String.t(),
          mounts_hash: String.t(),
          sykli_version: String.t()
        }

  @enforce_keys [:task_name, :command, :cached_at, :inputs_hash, :sykli_version]
  defstruct [
    :task_name,
    :command,
    :outputs,
    :duration_ms,
    :cached_at,
    :inputs_hash,
    :container,
    :env_hash,
    :mounts_hash,
    :sykli_version
  ]

  @doc """
  Creates a new cache entry.
  """
  @spec new(map()) :: t()
  def new(attrs) do
    %__MODULE__{
      task_name: attrs.task_name,
      command: attrs.command,
      outputs: attrs[:outputs] || [],
      duration_ms: attrs[:duration_ms] || 0,
      cached_at: attrs[:cached_at] || DateTime.utc_now(),
      inputs_hash: attrs.inputs_hash,
      container: attrs[:container] || "",
      env_hash: attrs[:env_hash] || "",
      mounts_hash: attrs[:mounts_hash] || "",
      sykli_version: attrs.sykli_version
    }
  end

  @doc """
  Converts a cache entry to a map suitable for JSON encoding.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry) do
    %{
      "task_name" => entry.task_name,
      "command" => entry.command,
      "outputs" => entry.outputs,
      "duration_ms" => entry.duration_ms,
      "cached_at" => DateTime.to_iso8601(entry.cached_at),
      "inputs_hash" => entry.inputs_hash,
      "container" => entry.container,
      "env_hash" => entry.env_hash,
      "mounts_hash" => entry.mounts_hash,
      "sykli_version" => entry.sykli_version
    }
  end

  @doc """
  Creates a cache entry from a JSON-decoded map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid}
  def from_map(map) when is_map(map) do
    cached_at =
      case DateTime.from_iso8601(map["cached_at"] || "") do
        {:ok, dt, _} -> dt
        _ -> DateTime.utc_now()
      end

    entry = %__MODULE__{
      task_name: map["task_name"],
      command: map["command"],
      outputs: map["outputs"] || [],
      duration_ms: map["duration_ms"] || 0,
      cached_at: cached_at,
      inputs_hash: map["inputs_hash"],
      container: map["container"] || "",
      env_hash: map["env_hash"] || "",
      mounts_hash: map["mounts_hash"] || "",
      sykli_version: map["sykli_version"]
    }

    {:ok, entry}
  rescue
    _ -> {:error, :invalid}
  end

  def from_map(_), do: {:error, :invalid}
end
