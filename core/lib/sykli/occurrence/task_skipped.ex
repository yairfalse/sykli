defmodule Sykli.Occurrence.TaskSkipped do
  @moduledoc "Typed payload for ci.task.skipped occurrences."

  @type reason :: :condition_not_met | :dependency_failed

  @type t :: %__MODULE__{
          task_name: String.t(),
          reason: reason()
        }

  @derive Jason.Encoder
  @enforce_keys [:task_name, :reason]
  defstruct [:task_name, :reason]

  @spec new(String.t(), reason()) :: t()
  def new(task_name, reason) do
    %__MODULE__{task_name: task_name, reason: reason}
  end
end
