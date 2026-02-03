defmodule Sykli.Events.RunStarted do
  @moduledoc """
  Typed event data for run_started events.

  Emitted when a pipeline run begins execution.
  """

  @type t :: %__MODULE__{
          project_path: String.t(),
          tasks: [String.t()],
          task_count: non_neg_integer()
        }

  @derive Jason.Encoder
  @enforce_keys [:project_path, :tasks, :task_count]
  defstruct [:project_path, :tasks, :task_count]

  @doc """
  Creates a new RunStarted event data struct.
  """
  @spec new(String.t(), [String.t()]) :: t()
  def new(project_path, tasks) do
    %__MODULE__{
      project_path: project_path,
      tasks: tasks,
      task_count: length(tasks)
    }
  end
end
