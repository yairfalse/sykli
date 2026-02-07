defmodule Sykli.Events.GateResolved do
  @moduledoc "Event data for when a gate is approved, denied, or times out."

  defstruct [:gate_name, :outcome, :approver, :duration_ms]

  @type outcome :: :approved | :denied | :timed_out
  @type t :: %__MODULE__{
          gate_name: String.t(),
          outcome: outcome(),
          approver: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  def new(gate_name, outcome, approver, duration_ms) do
    %__MODULE__{
      gate_name: gate_name,
      outcome: outcome,
      approver: approver,
      duration_ms: duration_ms
    }
  end
end
