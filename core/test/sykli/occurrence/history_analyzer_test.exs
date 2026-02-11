defmodule Sykli.Occurrence.HistoryAnalyzerTest do
  use ExUnit.Case, async: true

  alias Sykli.Occurrence.HistoryAnalyzer
  alias Sykli.RunHistory

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "history_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, workdir: test_dir}
  end

  describe "analyze/3" do
    test "returns empty maps when no history exists", %{workdir: workdir} do
      result = HistoryAnalyzer.analyze(["test", "build"], workdir)

      assert result["test"] == %{}
      assert result["build"] == %{}
    end

    test "computes stats from run history", %{workdir: workdir} do
      # Create some history
      for i <- 1..3 do
        save_run(workdir, %{
          id: "run-#{i}",
          overall: :passed,
          tasks: [
            %{name: "test", status: :passed, duration_ms: 3000 + i * 100}
          ]
        })
      end

      result = HistoryAnalyzer.analyze(["test"], workdir)

      assert result["test"]["pass_rate"] == 1.0
      assert is_integer(result["test"]["avg_duration_ms"])
    end

    test "detects flaky tasks", %{workdir: workdir} do
      # Alternating pass/fail
      save_run(workdir, %{
        id: "run-1",
        overall: :passed,
        tasks: [%{name: "test", status: :passed, duration_ms: 1000}]
      })

      save_run(workdir, %{
        id: "run-2",
        overall: :failed,
        tasks: [%{name: "test", status: :failed, duration_ms: 1000, error: "flaky fail"}]
      })

      result = HistoryAnalyzer.analyze(["test"], workdir)

      assert result["test"]["flaky"] == true
      assert result["test"]["pass_rate"] == 0.5
    end

    test "returns empty map for tasks not in history", %{workdir: workdir} do
      save_run(workdir, %{
        id: "run-1",
        overall: :passed,
        tasks: [%{name: "build", status: :passed, duration_ms: 1000}]
      })

      result = HistoryAnalyzer.analyze(["nonexistent"], workdir)

      assert result["nonexistent"] == %{}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp save_run(workdir, attrs) do
    timestamp = DateTime.utc_now()

    tasks =
      Enum.map(attrs.tasks, fn t ->
        %RunHistory.TaskResult{
          name: t.name,
          status: t.status,
          duration_ms: t.duration_ms,
          error: Map.get(t, :error),
          streak: 0
        }
      end)

    run = %RunHistory.Run{
      id: attrs.id,
      timestamp: timestamp,
      git_ref: "abc1234",
      git_branch: "main",
      tasks: tasks,
      overall: attrs.overall
    }

    RunHistory.save(run, path: workdir)

    # Small sleep to ensure unique timestamps for filenames
    Process.sleep(10)
  end
end
