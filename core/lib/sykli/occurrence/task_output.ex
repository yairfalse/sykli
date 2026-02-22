defmodule Sykli.Occurrence.TaskOutput do
  @moduledoc "Typed payload for ci.task.output occurrences."

  @type t :: %__MODULE__{
          task_name: String.t(),
          output: String.t()
        }

  @derive Jason.Encoder
  @enforce_keys [:task_name, :output]
  defstruct [:task_name, :output]

  @spec new(String.t(), String.t()) :: t()
  def new(task_name, output), do: %__MODULE__{task_name: task_name, output: output}
end
