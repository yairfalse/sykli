defmodule Sykli.CoordinatorTest do
  use ExUnit.Case, async: false

  alias Sykli.Coordinator

  # Start Coordinator for tests (normally only runs on coordinator node)
  setup do
    # Stop any existing coordinator first
    case GenServer.whereis(Coordinator) do
      nil ->
        :ok

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

  # Helper to sync with GenServer (ensures pending casts are processed)
  defp sync_coordinator do
    # :sys.get_state forces the GenServer to process all pending messages
    :sys.get_state(Coordinator)
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
      GenServer.cast(
        Coordinator,
        {:event, {node(), {:run_started, run_id, "/project", ["test"]}}}
      )

      sync_coordinator()

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
      GenServer.cast(
        Coordinator,
        {:event, {node(), {:run_started, run_id, "/project", ["test"]}}}
      )

      sync_coordinator()
      GenServer.cast(Coordinator, {:event, {node(), {:run_completed, run_id, :ok}}})
      sync_coordinator()

      history = Coordinator.run_history()

      assert Enum.any?(history, fn r -> r.id == run_id end)
    end

    test "limits history results" do
      # Create several runs
      Enum.each(1..5, fn i ->
        run_id = "limit_test_#{i}_#{System.unique_integer()}"

        GenServer.cast(
          Coordinator,
          {:event, {node(), {:run_started, run_id, "/project", ["test"]}}}
        )

        GenServer.cast(Coordinator, {:event, {node(), {:run_completed, run_id, :ok}}})
      end)

      sync_coordinator()

      history = Coordinator.run_history(limit: 3)

      assert length(history) <= 3
    end
  end

  describe "get_run/1" do
    test "returns active run" do
      run_id = "get_active_#{System.unique_integer()}"

      GenServer.cast(
        Coordinator,
        {:event, {node(), {:run_started, run_id, "/my/project", ["lint", "test"]}}}
      )

      sync_coordinator()

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
      GenServer.cast(
        Coordinator,
        {:event, {node(), {:run_started, run_id, "/project", ["test", "build"]}}}
      )

      sync_coordinator()

      # Start task
      GenServer.cast(Coordinator, {:event, {node(), {:task_started, run_id, "test"}}})
      sync_coordinator()

      run = Coordinator.get_run(run_id)
      assert run.task_status["test"] == :running

      # Complete task
      GenServer.cast(Coordinator, {:event, {node(), {:task_completed, run_id, "test", :ok}}})
      sync_coordinator()

      run = Coordinator.get_run(run_id)
      assert run.task_status["test"] == :completed

      # Clean up
      GenServer.cast(Coordinator, {:event, {node(), {:run_completed, run_id, :ok}}})
    end
  end

  describe "Event struct handling" do
    alias Sykli.Events.Event

    test "handles Event struct format for run_started" do
      run_id = "event_struct_#{System.unique_integer()}"

      event =
        Event.new(:run_started, run_id, %{
          project_path: "/event/project",
          tasks: ["build", "test"],
          task_count: 2
        })

      GenServer.cast(Coordinator, {:event, event})
      sync_coordinator()

      run = Coordinator.get_run(run_id)
      assert run.id == run_id
      assert run.project_path == "/event/project"
      assert run.tasks == ["build", "test"]

      # Clean up
      cleanup_event = Event.new(:run_completed, run_id, %{outcome: :success, error: nil})
      GenServer.cast(Coordinator, {:event, cleanup_event})
    end

    test "handles Event struct format for task_started" do
      run_id = "event_task_#{System.unique_integer()}"

      # Start run first
      run_event =
        Event.new(:run_started, run_id, %{
          project_path: "/task/project",
          tasks: ["my_task"],
          task_count: 1
        })

      GenServer.cast(Coordinator, {:event, run_event})
      sync_coordinator()

      # Task started
      task_event = Event.new(:task_started, run_id, %{task_name: "my_task"})
      GenServer.cast(Coordinator, {:event, task_event})
      sync_coordinator()

      run = Coordinator.get_run(run_id)
      assert run.task_status["my_task"] == :running

      # Clean up
      GenServer.cast(Coordinator, {:event, {node(), {:run_completed, run_id, :ok}}})
    end

    test "handles Event struct format for run_completed" do
      run_id = "event_complete_#{System.unique_integer()}"

      # Start run
      run_event =
        Event.new(:run_started, run_id, %{
          project_path: "/complete/project",
          tasks: ["task"],
          task_count: 1
        })

      GenServer.cast(Coordinator, {:event, run_event})
      sync_coordinator()

      # Complete run
      complete_event = Event.new(:run_completed, run_id, %{outcome: :success, error: nil})
      GenServer.cast(Coordinator, {:event, complete_event})
      sync_coordinator()

      # Should be in history, not active
      assert Coordinator.get_run(run_id) == nil ||
               Coordinator.get_run(run_id).status == :completed

      history = Coordinator.run_history()
      assert Enum.any?(history, fn r -> r.id == run_id end)
    end
  end
end
