defmodule Sykli.GitHub.Clock.Real do
  @moduledoc "Real clock backed by the mesh transport time source."

  @behaviour Sykli.GitHub.Clock

  @impl true
  def now_seconds, do: div(now_ms(), 1000)

  @impl true
  def now_ms, do: Sykli.Mesh.Transport.Erlang.now_ms()
end
