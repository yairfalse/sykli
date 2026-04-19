defmodule Sykli.Foo do
  def now, do: :os.system_time(:millisecond)
end
