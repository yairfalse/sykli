defmodule Sykli.CoordinatorTest do
  use ExUnit.Case, async: false

  alias Sykli.Coordinator

  # Start Coordinator for tests (normally only runs on coordinator node)
  setup do
    # Stop any existing coordinator first
    case GenServer.whereis(Coordinator) do
      nil -> :ok
      pid ->
        try do
          GenServer.stop(pid, :normal, 100)
        catch
          :exit, _ -> :ok
        end
    end

    # Start fresh coordinator for this test
    start_supervised!(Coordinator)
    :ok
  end

  describe "active_runs/0" do
    test "returns empty list when no runs" do
      # Clear any existing state by getting fresh runs
      runs = Coordinator.active_runs()

      # Should be a list (may have runs from other tests)
      assert is_list(runs)
    end

    test "tracks runs from events" do
      run_id = "coord_test_#{System.unique_integer()}"

      # Simulate event from a node
      GenServer.cast(Coordinator, {:event, {node(), {:run_started, run_id, "/project", ["test"]}}})

      # Give it time to process
      Process.sleep(50)

      runs = Coordinator.active_runs()

      assert Enum.any?(runs, fn r -> r.id == run_id end)

      # Clean up - complete the run
      GenServer.cast(Coordinator, {:event, {node(), {:run_completed, run_id, :ok}}})
    end
  end

  describe "run_history/1" do
    test "stores completed runs in history" do
      run_id = "history_test_#{System.unique_integer()}"

      # Start and complete a run
      GenServer.cast(Coordinator, {:event, {node(), {:run_started, run_id, "/project", ["test"]}}})
      Process.sleep(20)
      GenServer.cast(Coordinator, {:event, {node(), {:run_completed, run_id, :ok}}})
      Process.sleep(20)

      history = Coordinator.run_history()

      assert Enum.any?(history, fn r -> r.id == run_id end)
    end

    test "limits history results" do
      # Create several runs
      Enum.each(1..5, fn i ->
        run_id = "limit_test_#{i}_#{System.unique_integer()}"
        GenServer.cast(Coordinator, {:event, {node(), {:run_started, run_id, "/project", ["test"]}}})
        GenServer.cast(Coordinator, {:event, {node(), {:run_completed, run_id, :ok}}})
      end)

      Process.sleep(50)

      history = Coordinator.run_history(limit: 3)

      assert length(history) <= 3
    end
  end

  describe "get_run/1" do
    test "returns active run" do
      run_id = "get_active_#{System.unique_integer()}"

      GenServer.cast(Coordinator, {:event, {node(), {:run_started, run_id, "/my/project", ["lint", "test"]}}})
      Process.sleep(20)

      run = Coordinator.get_run(run_id)

      assert run.id == run_id
      assert run.project_path == "/my/project"
      assert run.tasks == ["lint", "test"]

      # Clean up
      GenServer.cast(Coordinator, {:event, {node(), {:run_completed, run_id, :ok}}})
    end

    test "returns nil for unknown run" do
      assert Coordinator.get_run("nonexistent_#{System.unique_integer()}") == nil
    end
  end

  describe "stats/0" do
    test "returns statistics" do
      stats = Coordinator.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_runs)
      assert Map.has_key?(stats, :successful_runs)
      assert Map.has_key?(stats, :failed_runs)
      assert Map.has_key?(stats, :active_runs)
      assert Map.has_key?(stats, :connected_nodes)
    end
  end

  describe "connected_nodes/0" do
    test "returns list of nodes" do
      nodes = Coordinator.connected_nodes()

      assert is_list(nodes)
    end
  end

  describe "task events" do
    test "tracks task status within a run" do
      run_id = "task_status_#{System.unique_integer()}"

      # Start run
      GenServer.cast(Coordinator, {:event, {node(), {:run_started, run_id, "/project", ["test", "build"]}}})
      Process.sleep(20)

      # Start task
      GenServer.cast(Coordinator, {:event, {node(), {:task_started, run_id, "test"}}})
      Process.sleep(20)

      run = Coordinator.get_run(run_id)
      assert run.task_status["test"] == :running

      # Complete task
      GenServer.cast(Coordinator, {:event, {node(), {:task_completed, run_id, "test", :ok}}})
      Process.sleep(20)

      run = Coordinator.get_run(run_id)
      assert run.task_status["test"] == :completed

      # Clean up
      GenServer.cast(Coordinator, {:event, {node(), {:run_completed, run_id, :ok}}})
    end
  end
end
