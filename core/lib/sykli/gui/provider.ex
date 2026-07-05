defmodule Sykli.Gui.Provider do
  @moduledoc """
  The single seam between the Workbench UI and its data.

  Everything the GUI shows flows through this behaviour so the demo and
  real (artifact-backed) providers are interchangeable — the web layer
  never knows whether data is fake or real, and never scrapes CLI text.

  Select via config: `config :sykli, :gui_provider, Sykli.Gui.Provider.Demo`.
  """

  @callback state(opts :: keyword()) :: Sykli.Gui.State.t()
  @callback run(id :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback approve_gate(id :: String.t(), actor :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback reject_gate(id :: String.t(), actor :: String.t(), reason :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc "The configured provider module (default: the demo provider)."
  def current do
    Application.get_env(:sykli, :gui_provider, Sykli.Gui.Provider.Demo)
  end
end
