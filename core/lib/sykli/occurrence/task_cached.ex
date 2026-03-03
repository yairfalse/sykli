defmodule Sykli.Occurrence.TaskCached do
  @moduledoc "Typed payload for ci.task.cached occurrences."

  @type t :: %__MODULE__{
          task_name: String.t(),
          cache_key: String.t() | nil
        }

  @derive Jason.Encoder
  @enforce_keys [:task_name]
  defstruct [:task_name, :cache_key]

  @spec new(String.t(), String.t() | nil) :: t()
  def new(task_name, cache_key \\ nil) do
    %__MODULE__{task_name: task_name, cache_key: cache_key}
  end
end
