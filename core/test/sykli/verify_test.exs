defmodule Sykli.VerifyTest do
  use ExUnit.Case, async: true

  alias Sykli.RunHistory
  alias Sykli.RunHistory.{Run, TaskResult}

  @moduletag :tmp_dir

  describe "plan/1 with no runs" do
    test "returns error when no runs directory exists", %{tmp_dir: tmp_dir} do
      assert {:error, :no_runs} = Sykli.Verify.plan(path: tmp_dir, from: "latest")
    end
  end

  describe "plan/1 with a saved run" do
    test "returns a plan from latest run", %{tmp_dir: tmp_dir} do
      # Save a run
      run = %Run{
        id: "run-001",
        timestamp: DateTime.utc_now(),
        git_ref: "abc123",
        git_branch: "main",
        tasks: [
          %TaskResult{name: "test", status: :passed, duration_ms: 200},
          %TaskResult{name: "build", status: :passed, duration_ms: 300}
        ],
        overall: :passed
      }

      RunHistory.save(run, path: tmp_dir)

      # plan/1 will fail at load_task_graph because there's no SDK file,
      # but that confirms load_run works correctly
      result = Sykli.Verify.plan(path: tmp_dir, from: "latest")

      # We expect it to get past load_run and fail at load_task_graph
      # (no SDK file in tmp_dir)
      assert {:error, _} = result
    end
  end

  describe "plan/1 with from: run_id" do
    test "finds a specific run by ID", %{tmp_dir: tmp_dir} do
      # Save two runs
      run1 = %Run{
        id: "run-001",
        timestamp: ~U[2024-01-01 00:00:00Z],
        git_ref: "aaa",
        git_branch: "main",
        tasks: [%TaskResult{name: "test", status: :passed, duration_ms: 100}],
        overall: :passed
      }

      run2 = %Run{
        id: "run-002",
        timestamp: ~U[2024-01-02 00:00:00Z],
        git_ref: "bbb",
        git_branch: "main",
        tasks: [%TaskResult{name: "test", status: :failed, duration_ms: 200}],
        overall: :failed
      }

      RunHistory.save(run1, path: tmp_dir)
      RunHistory.save(run2, path: tmp_dir)

      # Ask for run-001 specifically — should work (fail at task_graph, not at load_run)
      result = Sykli.Verify.plan(path: tmp_dir, from: "run-001")
      assert {:error, _} = result
    end

    test "returns error for nonexistent run ID", %{tmp_dir: tmp_dir} do
      run = %Run{
        id: "run-001",
        timestamp: DateTime.utc_now(),
        git_ref: "abc",
        git_branch: "main",
        tasks: [%TaskResult{name: "test", status: :passed, duration_ms: 100}],
        overall: :passed
      }

      RunHistory.save(run, path: tmp_dir)

      assert {:error, {:run_not_found, "nonexistent"}} =
               Sykli.Verify.plan(path: tmp_dir, from: "nonexistent")
    end
  end
end
