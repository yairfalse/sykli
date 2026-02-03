defmodule Sykli.Events.RunCompleted do
  @moduledoc """
  Typed event data for run_completed events.

  Emitted when a pipeline run finishes (success or failure).
  """

  @type outcome :: :success | :failure

  @type t :: %__MODULE__{
          outcome: outcome(),
          error: term() | nil
        }

  @derive Jason.Encoder
  @enforce_keys [:outcome]
  defstruct [:outcome, :error]

  @doc """
  Creates a RunCompleted event data for a successful run.
  """
  @spec success() :: t()
  def success do
    %__MODULE__{outcome: :success, error: nil}
  end

  @doc """
  Creates a RunCompleted event data for a failed run.
  """
  @spec failure(term()) :: t()
  def failure(error) do
    %__MODULE__{outcome: :failure, error: error}
  end

  @doc """
  Creates a RunCompleted event data from a result tuple.
  """
  @spec from_result(:ok | {:error, term()}) :: t()
  def from_result(:ok), do: success()
  def from_result({:error, reason}), do: failure(reason)
end
