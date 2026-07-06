defmodule Sykli.CLI.GuiTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "rejects invalid port values without starting a server" do
    stderr =
      capture_io(:stderr, fn ->
        assert Sykli.CLI.Gui.main(["--port", "eighty"]) == 1
      end)

    assert stderr =~ "invalid --port value"
  end

  test "rejects unknown flags" do
    stderr =
      capture_io(:stderr, fn ->
        assert Sykli.CLI.Gui.main(["--fancy"]) == 1
      end)

    assert stderr =~ "unknown gui flag"
  end

  test "--json errors use the shared envelope" do
    output =
      capture_io(fn ->
        assert Sykli.CLI.Gui.main(["--port", "0", "--json"]) == 1
      end)

    assert %{"ok" => false, "version" => "1", "error" => %{"message" => msg}} =
             Jason.decode!(output)

    assert msg =~ "invalid --port"
  end
end
