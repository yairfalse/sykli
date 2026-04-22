defmodule Sykli.Occurrence.GateWaiting do
  @moduledoc "Typed payload for ci.gate.waiting occurrences."

  @derive Jason.Encoder
  defstruct [:gate_name, :strategy, :message, :timeout]

  @type t :: %__MODULE__{
          gate_name: String.t(),
          strategy: atom(),
          message: String.t() | nil,
          timeout: pos_integer()
        }

  def new(gate_name, strategy, message, timeout) do
    %__MODULE__{gate_name: gate_name, strategy: strategy, message: message, timeout: timeout}
  end
end
