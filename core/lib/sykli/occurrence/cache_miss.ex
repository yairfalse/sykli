defmodule Sykli.Occurrence.CacheMiss do
  @moduledoc """
  Typed payload for ci.cache.miss occurrences.

  `cache_key_version` distinguishes the hashing scheme that produced the key.
  v1 (pre-2026-04) used sha256(origin_url) only and is not comparable to v2 (origin_url + workdir, or absolute_path for non-git projects).
  """

  @type t :: %__MODULE__{
          task_name: String.t(),
          cache_key: String.t() | nil,
          reason: String.t() | nil,
          cache_key_version: String.t()
        }

  @derive Jason.Encoder
  @enforce_keys [:task_name]
  defstruct [:task_name, :cache_key, :reason, cache_key_version: "2"]

  @spec new(String.t(), String.t() | nil, String.t() | nil) :: t()
  def new(task_name, cache_key \\ nil, reason \\ nil) do
    %__MODULE__{task_name: task_name, cache_key: cache_key, reason: reason}
  end
end
