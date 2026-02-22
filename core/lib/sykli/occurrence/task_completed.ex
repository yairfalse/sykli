defmodule Sykli.Occurrence.TaskCompleted do
  @moduledoc "Typed payload for ci.task.completed occurrences."

  @type outcome :: :success | :failure

  @type t :: %__MODULE__{
          task_name: String.t(),
          outcome: outcome(),
          error: term() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @derive Jason.Encoder
  @enforce_keys [:task_name, :outcome]
  defstruct [:task_name, :outcome, :error, :duration_ms]

  @spec success(String.t(), non_neg_integer() | nil) :: t()
  def success(task_name, duration_ms \\ nil) do
    %__MODULE__{task_name: task_name, outcome: :success, error: nil, duration_ms: duration_ms}
  end

  @spec failure(String.t(), term(), non_neg_integer() | nil) :: t()
  def failure(task_name, error, duration_ms \\ nil) do
    %__MODULE__{task_name: task_name, outcome: :failure, error: error, duration_ms: duration_ms}
  end

  @spec from_result(String.t(), :ok | {:error, term()}, non_neg_integer() | nil) :: t()
  def from_result(task_name, :ok, duration_ms), do: success(task_name, duration_ms)

  def from_result(task_name, {:error, reason}, duration_ms),
    do: failure(task_name, reason, duration_ms)
end
