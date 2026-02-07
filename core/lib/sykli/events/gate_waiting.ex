defmodule Sykli.Events.GateWaiting do
  @moduledoc "Event data for when a gate starts waiting for approval."

  defstruct [:gate_name, :strategy, :message, :timeout]

  @type t :: %__MODULE__{
          gate_name: String.t(),
          strategy: atom(),
          message: String.t() | nil,
          timeout: pos_integer()
        }

  def new(gate_name, strategy, message, timeout) do
    %__MODULE__{
      gate_name: gate_name,
      strategy: strategy,
      message: message,
      timeout: timeout
    }
  end
end
