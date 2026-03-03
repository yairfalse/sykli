defmodule Sykli.Occurrence.CacheMiss do
  @moduledoc "Typed payload for ci.cache.miss occurrences."

  @type t :: %__MODULE__{
          task_name: String.t(),
          cache_key: String.t() | nil,
          reason: String.t() | nil
        }

  @derive Jason.Encoder
  @enforce_keys [:task_name]
  defstruct [:task_name, :cache_key, :reason]

  @spec new(String.t(), String.t() | nil, String.t() | nil) :: t()
  def new(task_name, cache_key \\ nil, reason \\ nil) do
    %__MODULE__{task_name: task_name, cache_key: cache_key, reason: reason}
  end
end
