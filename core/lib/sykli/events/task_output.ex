defmodule Sykli.Events.TaskOutput do
  @moduledoc """
  Typed event data for task_output events.

  Emitted when a task produces output during execution.
  """

  @type t :: %__MODULE__{
          task_name: String.t(),
          output: String.t()
        }

  @derive Jason.Encoder
  @enforce_keys [:task_name, :output]
  defstruct [:task_name, :output]

  @doc """
  Creates a new TaskOutput event data struct.
  """
  @spec new(String.t(), String.t()) :: t()
  def new(task_name, output) do
    %__MODULE__{task_name: task_name, output: output}
  end
end
