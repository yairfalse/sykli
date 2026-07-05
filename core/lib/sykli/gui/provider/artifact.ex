defmodule Sykli.Gui.Provider.Artifact do
  @moduledoc """
  Artifact-backed Workbench provider (stub).

  Will build the same `%Sykli.Gui.State{}` the demo provider returns, but
  from real local sources: `.sykli/runs/` manifests, `Work.Store`,
  `Gate.Store`, the emitted contract, occurrence activity, and — once
  Team Mode is joined — coordinator team state. The UI must not change
  when this lands; that is the point of the provider seam.
  """

  @behaviour Sykli.Gui.Provider

  @impl true
  def state(_opts), do: raise("Sykli.Gui.Provider.Artifact is not implemented yet")

  @impl true
  def run(_id), do: {:error, :not_implemented}

  @impl true
  def approve_gate(_id, _actor), do: {:error, :not_implemented}

  @impl true
  def reject_gate(_id, _actor, _reason), do: {:error, :not_implemented}
end
