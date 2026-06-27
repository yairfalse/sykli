defmodule Sykli.ProgressTest do
  @moduledoc """
  Executor presentation contract.

  This file used to assert on the legacy `Sykli.Executor.Output` live-print text
  (progress counters, a `"Level"` header, an inline run summary, etc.). That
  subsystem was retired in #256: the executor is now silent by default and
  emits presentation events through a configurable sink, while
  `Sykli.CLI.Renderer` presents the final results. These tests pin the new
  contract.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  defmodule ProbeSink do
    @moduledoc false
    @behaviour Sykli.Executor.Output.Sink

    @impl true
    def task_starting(_prefix, name, _reason), do: relay({:sink, :task_starting, name})

    @impl true
    def task_cached(_prefix, name), do: relay({:sink, :task_cached, name})

    @impl true
    def summary(_results, _total, status, _tasks), do: relay({:sink, :summary, status})

    defp relay(msg) do
      case Application.get_env(:sykli, :progress_test_probe) do
        pid when is_pid(pid) -> send(pid, msg)
        _ -> :ok
      end
    end
  end

  defp make_task(name, command, opts \\ []) do
    %Sykli.Graph.Task{
      name: name,
      command: command,
      depends_on: Keyword.get(opts, :depends_on, []),
      inputs: [],
      outputs: [],
      container: nil,
      workdir: nil,
      env: %{},
      mounts: []
    }
  end

  describe "executor presentation contract" do
    test "the executor no longer emits the legacy live-print presentation (#256)" do
      # `true` produces no stdout, so anything captured would be presentation.
      tasks = [make_task("alpha", "true"), make_task("beta", "true")]
      graph = Map.new(tasks, fn t -> {t.name, t} end)

      output =
        capture_io(fn ->
          Sykli.Executor.run(tasks, graph, workdir: "/tmp")
        end)

      # Retired Sykli.Executor.Output markers must not appear: the banned "Level"
      # header, the [n/total] progress counter, the ▶ task glyph, and the inline
      # "N passed" summary (the duplicate-summary regression). Presentation is now
      # Sykli.CLI.Renderer's job, applied by the CLI after the run.
      refute output =~ "Level"
      refute output =~ "▶"
      refute output =~ ~r/\[\d+\/\d+\]/
      refute output =~ ~r/\d+ passed/
    end

    test "a registered output sink receives executor events" do
      Application.put_env(:sykli, :progress_test_probe, self())
      Application.put_env(:sykli, :executor_output_sink, ProbeSink)

      on_exit(fn ->
        Application.delete_env(:sykli, :executor_output_sink)
        Application.delete_env(:sykli, :progress_test_probe)
      end)

      tasks = [make_task("test", "echo #{System.unique_integer([:positive])}")]
      graph = Map.new(tasks, fn t -> {t.name, t} end)

      # The sink is silent w.r.t. stdout; we observe it via the relayed messages.
      capture_io(fn ->
        Sykli.Executor.run(tasks, graph, workdir: "/tmp")
      end)

      # Every run ends with a summary event; that proves the executor → Output →
      # sink path is wired.
      assert_received {:sink, :summary, status} when status in [:ok, :error]
    end
  end
end
