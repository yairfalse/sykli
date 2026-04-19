defmodule Sykli.Mesh.Transport.Erlang do
  def now, do: System.monotonic_time(:millisecond)
end
