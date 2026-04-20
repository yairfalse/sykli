defmodule Mix.Tasks.Sykli.Runtime.InfoTest do
  @moduledoc """
  Tests for `mix sykli.runtime.info`.

  Uses `Mix.Task.rerun/1` to invoke and `ExUnit.CaptureIO` (via Mix.shell/0)
  to capture stdout. async: false because Mix.shell state is global.
  """

  use ExUnit.Case, async: false

  setup do
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(prev_shell) end)
    :ok
  end

  test "prints both the container runtime and the containerless runtime" do
    Mix.Task.rerun("sykli.runtime.info", [])

    messages = drain_messages([])
    joined = Enum.join(messages, "\n")

    assert joined =~ "Container runtime:"
    assert joined =~ "Containerless runtime:"
    assert joined =~ "Available runtimes:"
  end

  test "lists each known runtime with an availability marker" do
    Mix.Task.rerun("sykli.runtime.info", [])

    joined = drain_messages([]) |> Enum.join("\n")

    for module <- [
          Sykli.Runtime.Docker,
          Sykli.Runtime.Podman,
          Sykli.Runtime.Shell,
          Sykli.Runtime.Fake
        ] do
      assert joined =~ inspect(module),
             "expected #{inspect(module)} in output:\n#{joined}"
    end

    assert joined =~ ~r/\(available\)|\(not available\)/
  end

  defp drain_messages(acc) do
    receive do
      {:mix_shell, :info, [line]} -> drain_messages([line | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
