defmodule Sykli.Occurrence.RunCompleted do
  @moduledoc "Typed payload for ci.run.passed / ci.run.failed occurrences."

  @type outcome :: :success | :failure

  @type t :: %__MODULE__{
          outcome: outcome(),
          error: term() | nil
        }

  @derive Jason.Encoder
  @enforce_keys [:outcome]
  defstruct [:outcome, :error]

  @spec success() :: t()
  def success, do: %__MODULE__{outcome: :success, error: nil}

  @spec failure(term()) :: t()
  def failure(error), do: %__MODULE__{outcome: :failure, error: error}

  @spec from_result(:ok | {:error, term()}) :: t()
  def from_result(:ok), do: success()
  def from_result({:error, reason}), do: failure(reason)
end
