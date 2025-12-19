defmodule Sykli.RunRegistryTest do
  use ExUnit.Case, async: false

  alias Sykli.RunRegistry

  describe "start_run/2" do
    test "creates a run with unique ID" do
      {:ok, run_id} = RunRegistry.start_run("/project", ["test", "build"])

      assert is_binary(run_id)
      assert String.starts_with?(run_id, "run_")
    end

    test "each run gets a unique ID" do
      {:ok, id1} = RunRegistry.start_run("/project1", ["test"])
      {:ok, id2} = RunRegistry.start_run("/project2", ["build"])

      assert id1 != id2
    end
  end

  describe "get_run/1" do
    test "returns the run info" do
      {:ok, run_id} = RunRegistry.start_run("/my/project", ["lint", "test"])

      {:ok, run} = RunRegistry.get_run(run_id)

      assert run.id == run_id
      assert run.project_path == "/my/project"
      assert run.tasks == ["lint", "test"]
      assert run.status == :pending
      assert run.node == node()
    end

    test "returns error for unknown run" do
      assert {:error, :not_found} = RunRegistry.get_run("nonexistent_run")
    end
  end

  describe "update_status/2" do
    test "updates run status" do
      {:ok, run_id} = RunRegistry.start_run("/project", ["test"])

      :ok = RunRegistry.update_status(run_id, :running)

      {:ok, run} = RunRegistry.get_run(run_id)
      assert run.status == :running
    end

    test "returns error for unknown run" do
      assert {:error, :not_found} = RunRegistry.update_status("nonexistent", :running)
    end
  end

  describe "complete_run/2" do
    test "marks run as completed with ok result" do
      {:ok, run_id} = RunRegistry.start_run("/project", ["test"])
      RunRegistry.update_status(run_id, :running)

      :ok = RunRegistry.complete_run(run_id, :ok)

      {:ok, run} = RunRegistry.get_run(run_id)
      assert run.status == :completed
      assert run.result == :ok
      assert run.completed_at != nil
    end

    test "marks run as failed with error result" do
      {:ok, run_id} = RunRegistry.start_run("/project", ["test"])

      :ok = RunRegistry.complete_run(run_id, {:error, :test_failed})

      {:ok, run} = RunRegistry.get_run(run_id)
      assert run.status == :failed
      assert run.result == {:error, :test_failed}
    end
  end

  describe "list_runs/1" do
    test "lists all runs" do
      # Start a few runs
      {:ok, _} = RunRegistry.start_run("/p1", ["test"])
      {:ok, _} = RunRegistry.start_run("/p2", ["build"])

      runs = RunRegistry.list_runs()

      assert length(runs) >= 2
    end

    test "filters by status" do
      {:ok, run_id} = RunRegistry.start_run("/project", ["test"])
      RunRegistry.update_status(run_id, :running)

      running = RunRegistry.list_runs(status: :running)

      assert Enum.any?(running, fn r -> r.id == run_id end)
    end

    test "limits results" do
      Enum.each(1..5, fn i ->
        RunRegistry.start_run("/project#{i}", ["test"])
      end)

      runs = RunRegistry.list_runs(limit: 3)

      assert length(runs) <= 3
    end
  end

  describe "active_runs/0" do
    test "returns only running tasks" do
      {:ok, running_id} = RunRegistry.start_run("/running", ["test"])
      RunRegistry.update_status(running_id, :running)

      {:ok, pending_id} = RunRegistry.start_run("/pending", ["build"])

      active = RunRegistry.active_runs()

      assert Enum.any?(active, fn r -> r.id == running_id end)
      refute Enum.any?(active, fn r -> r.id == pending_id end)
    end
  end
end
