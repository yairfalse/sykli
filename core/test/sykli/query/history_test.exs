defmodule Sykli.Query.HistoryTest do
  use ExUnit.Case, async: true

  alias Sykli.Query.History
  alias Sykli.RunHistory
  alias Sykli.RunHistory.{Run, TaskResult}

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "query_history_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, workdir: test_dir}
  end

  describe "why_failed/3" do
    test "finds most recent failure for a task", %{workdir: workdir} do
      save_run(workdir, :failed, ~U[2026-02-20 10:00:00Z], [
        {"build", :failed, 3000, "exit code 1"}
      ])

      {:ok, result} = History.why_failed("build", :latest, workdir)

      assert result.type == :history
      assert result.data.task == "build"
      assert result.data.status == :failed
      assert result.data.error == "exit code 1"
    end

    test "returns error when task has not failed", %{workdir: workdir} do
      save_run(workdir, :passed, ~U[2026-02-20 10:00:00Z], [
        {"build", :passed, 3000, nil}
      ])

      assert {:error, {:no_failure_found, "build"}} =
               History.why_failed("build", :latest, workdir)
    end

    test "returns error when task doesn't exist in history", %{workdir: workdir} do
      save_run(workdir, :passed, ~U[2026-02-20 10:00:00Z], [
        {"test", :passed, 3000, nil}
      ])

      assert {:error, {:no_failure_found, "nonexistent"}} =
               History.why_failed("nonexistent", :latest, workdir)
    end
  end

  describe "last_pass/2" do
    test "finds most recent pass for a task", %{workdir: workdir} do
      save_run(workdir, :passed, ~U[2026-02-20 10:00:00Z], [
        {"test", :passed, 2000, nil}
      ])

      {:ok, result} = History.last_pass("test", workdir)

      assert result.data.task == "test"
      assert result.data.status == :passed
      assert result.data.duration_ms == 2000
    end

    test "returns error when task has never passed", %{workdir: workdir} do
      save_run(workdir, :failed, ~U[2026-02-20 10:00:00Z], [
        {"test", :failed, 3000, "error"}
      ])

      assert {:error, {:no_pass_found, "test"}} = History.last_pass("test", workdir)
    end
  end

  # Helpers

  defp save_run(workdir, overall, timestamp, task_results) do
    tasks =
      Enum.map(task_results, fn {name, status, duration_ms, error} ->
        %TaskResult{name: name, status: status, duration_ms: duration_ms, error: error}
      end)

    run = %Run{
      id: "run-#{:erlang.unique_integer([:positive])}",
      timestamp: timestamp,
      git_ref: "abc123",
      git_branch: "main",
      tasks: tasks,
      overall: overall
    }

    RunHistory.save(run, path: workdir)
  end
end
