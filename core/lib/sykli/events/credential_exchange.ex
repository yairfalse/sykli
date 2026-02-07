defmodule Sykli.Events.CredentialExchange do
  @moduledoc "Event data for OIDC credential exchange."

  defstruct [:task_name, :provider, :outcome, :duration_ms]

  @type t :: %__MODULE__{
    task_name: String.t(),
    provider: atom(),
    outcome: :success | :failure,
    duration_ms: non_neg_integer()
  }

  def new(task_name, provider, outcome, duration_ms) do
    %__MODULE__{
      task_name: task_name,
      provider: provider,
      outcome: outcome,
      duration_ms: duration_ms
    }
  end
end
