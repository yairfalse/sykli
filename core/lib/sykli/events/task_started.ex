defmodule Sykli.Events.TaskStarted do
  @moduledoc """
  Typed event data for task_started events.

  Emitted when a task begins execution.
  """

  @type t :: %__MODULE__{
          task_name: String.t()
        }

  @derive Jason.Encoder
  @enforce_keys [:task_name]
  defstruct [:task_name]

  @doc """
  Creates a new TaskStarted event data struct.
  """
  @spec new(String.t()) :: t()
  def new(task_name) do
    %__MODULE__{task_name: task_name}
  end
end
