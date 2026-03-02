defmodule Sykli.Query.HealthTest do
  use ExUnit.Case, async: true

  alias Sykli.Query.Health
  alias Sykli.RunHistory
  alias Sykli.RunHistory.{Run, TaskResult}

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "query_health_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, workdir: test_dir}
  end

  describe "flaky tasks" do
    test "detects tasks with both passes and failures", %{workdir: workdir} do
      save_run(workdir, :passed, ~U[2026-02-20 10:00:00Z], [
        {"test", :passed, 3000},
        {"e2e", :passed, 5000}
      ])

      save_run(workdir, :failed, ~U[2026-02-19 10:00:00Z], [
        {"test", :passed, 3000},
        {"e2e", :failed, 5000}
      ])

      {:ok, result} = Health.execute(:flaky, workdir)

      assert result.type == :health
      assert result.data.metric == :flaky
      assert length(result.data.tasks) == 1

      [flaky] = result.data.tasks
      assert flaky.name == "e2e"
      assert flaky.failures == 1
      assert flaky.total_runs == 2
    end

    test "returns empty when no flaky tasks", %{workdir: workdir} do
      save_run(workdir, :passed, ~U[2026-02-20 10:00:00Z], [
        {"test", :passed, 3000}
      ])

      {:ok, result} = Health.execute(:flaky, workdir)
      assert result.data.tasks == []
    end
  end

  describe "failure rate" do
    test "computes success rate from runs", %{workdir: workdir} do
      save_run(workdir, :passed, ~U[2026-02-20 10:00:00Z], [{"test", :passed, 3000}])
      save_run(workdir, :failed, ~U[2026-02-19 10:00:00Z], [{"test", :failed, 4000}])

      {:ok, result} = Health.execute(:failure_rate, workdir)

      assert result.data.total_runs == 2
      assert result.data.passed == 1
      assert result.data.failed == 1
      assert result.data.success_rate == 0.5
    end
  end

  describe "slowest tasks" do
    test "ranks tasks by average duration", %{workdir: workdir} do
      save_run(workdir, :passed, ~U[2026-02-20 10:00:00Z], [
        {"fast", :passed, 100},
        {"slow", :passed, 10000}
      ])

      {:ok, result} = Health.execute(:slowest, workdir)

      [first | _] = result.data.tasks
      assert first.name == "slow"
      assert first.avg_ms == 10000
    end
  end

  describe "summary" do
    test "aggregates all health metrics", %{workdir: workdir} do
      save_run(workdir, :passed, ~U[2026-02-20 10:00:00Z], [
        {"test", :passed, 3000}
      ])

      {:ok, result} = Health.execute(:summary, workdir)

      assert result.data.metric == :summary
      assert result.data.recent_runs == 1
      assert result.data.success_rate == 1.0
      assert result.data.last_success != nil
    end
  end

  describe "error handling" do
    test "returns error when no runs exist", %{workdir: workdir} do
      assert {:error, :no_runs} = Health.execute(:flaky, workdir)
    end
  end

  # Helpers

  defp save_run(workdir, overall, timestamp, task_results) do
    tasks =
      Enum.map(task_results, fn {name, status, duration_ms} ->
        %TaskResult{name: name, status: status, duration_ms: duration_ms}
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
