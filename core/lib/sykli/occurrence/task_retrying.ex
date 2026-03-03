defmodule Sykli.Occurrence.TaskRetrying do
  @moduledoc "Typed payload for ci.task.retrying occurrences."

  @type t :: %__MODULE__{
          task_name: String.t(),
          attempt: pos_integer(),
          max_attempts: pos_integer(),
          error: term() | nil
        }

  @derive Jason.Encoder
  @enforce_keys [:task_name, :attempt, :max_attempts]
  defstruct [:task_name, :attempt, :max_attempts, :error]

  @spec new(String.t(), pos_integer(), pos_integer(), term()) :: t()
  def new(task_name, attempt, max_attempts, error \\ nil) do
    %__MODULE__{
      task_name: task_name,
      attempt: attempt,
      max_attempts: max_attempts,
      error: error
    }
  end
end
