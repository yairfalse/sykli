defmodule Sykli.Occurrence.TaskStarted do
  @moduledoc "Typed payload for ci.task.started occurrences."

  @type t :: %__MODULE__{task_name: String.t()}

  @derive Jason.Encoder
  @enforce_keys [:task_name]
  defstruct [:task_name]

  @spec new(String.t()) :: t()
  def new(task_name), do: %__MODULE__{task_name: task_name}
end
