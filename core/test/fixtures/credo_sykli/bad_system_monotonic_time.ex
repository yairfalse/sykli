defmodule Sykli.Foo do
  def now, do: System.monotonic_time(:millisecond)
end
