defmodule Sykli.Occurrence.RunStarted do
  @moduledoc "Typed payload for ci.run.started occurrences."

  @type t :: %__MODULE__{
          project_path: String.t(),
          tasks: [String.t()],
          task_count: non_neg_integer()
        }

  @derive Jason.Encoder
  @enforce_keys [:project_path, :tasks, :task_count]
  defstruct [:project_path, :tasks, :task_count]

  @spec new(String.t(), [String.t()]) :: t()
  def new(project_path, tasks) do
    %__MODULE__{
      project_path: project_path,
      tasks: tasks,
      task_count: length(tasks)
    }
  end
end
