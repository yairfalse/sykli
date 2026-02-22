defmodule Sykli.CoordinatorTest do
  use ExUnit.Case, async: false

  alias Sykli.Coordinator
  alias Sykli.Occurrence

  setup do
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

    start_supervised!(Coordinator)
    :ok
  end

  defp sync_coordinator do
    :sys.get_state(Coordinator)
    :ok
  end

  describe "active_runs/0" do
    test "returns empty list when no runs" do
      runs = Coordinator.active_runs()
      assert is_list(runs)
    end

    test "tracks runs from occurrences" do
      run_id = "coord_test_#{System.unique_integer()}"

      occ = Occurrence.run_started(run_id, "/project", ["test"])
      GenServer.cast(Coordinator, {:occurrence, occ})

      sync_coordinator()

      runs = Coordinator.active_runs()
      assert Enum.any?(runs, fn r -> r.id == run_id end)

      # Clean up
      cleanup = Occurrence.run_completed(run_id, :ok)
      GenServer.cast(Coordinator, {:occurrence, cleanup})
    end
  end

  describe "run_history/1" do
    test "stores completed runs in history" do
      run_id = "history_test_#{System.unique_integer()}"

      start_occ = Occurrence.run_started(run_id, "/project", ["test"])
      GenServer.cast(Coordinator, {:occurrence, start_occ})
      sync_coordinator()

      complete_occ = Occurrence.run_completed(run_id, :ok)
      GenServer.cast(Coordinator, {:occurrence, complete_occ})
      sync_coordinator()

      history = Coordinator.run_history()
      assert Enum.any?(history, fn r -> r.id == run_id end)
    end

    test "limits history results" do
      Enum.each(1..5, fn i ->
        run_id = "limit_test_#{i}_#{System.unique_integer()}"

        start_occ = Occurrence.run_started(run_id, "/project", ["test"])
        GenServer.cast(Coordinator, {:occurrence, start_occ})

        complete_occ = Occurrence.run_completed(run_id, :ok)
        GenServer.cast(Coordinator, {:occurrence, complete_occ})
      end)

      sync_coordinator()

      history = Coordinator.run_history(limit: 3)
      assert length(history) <= 3
    end
  end

  describe "get_run/1" do
    test "returns active run" do
      run_id = "get_active_#{System.unique_integer()}"

      occ = Occurrence.run_started(run_id, "/my/project", ["lint", "test"])
      GenServer.cast(Coordinator, {:occurrence, occ})

      sync_coordinator()

      run = Coordinator.get_run(run_id)
      assert run.id == run_id
      assert run.project_path == "/my/project"
      assert run.tasks == ["lint", "test"]

      # Clean up
      cleanup = Occurrence.run_completed(run_id, :ok)
      GenServer.cast(Coordinator, {:occurrence, cleanup})
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

  describe "task occurrences" do
    test "tracks task status within a run" do
      run_id = "task_status_#{System.unique_integer()}"

      start_occ = Occurrence.run_started(run_id, "/project", ["test", "build"])
      GenServer.cast(Coordinator, {:occurrence, start_occ})
      sync_coordinator()

      task_occ = Occurrence.task_started(run_id, "test")
      GenServer.cast(Coordinator, {:occurrence, task_occ})
      sync_coordinator()

      run = Coordinator.get_run(run_id)
      assert run.task_status["test"] == :running

      complete_occ = Occurrence.task_completed(run_id, "test", :ok)
      GenServer.cast(Coordinator, {:occurrence, complete_occ})
      sync_coordinator()

      run = Coordinator.get_run(run_id)
      assert run.task_status["test"] == :completed

      # Clean up
      cleanup = Occurrence.run_completed(run_id, :ok)
      GenServer.cast(Coordinator, {:occurrence, cleanup})
    end
  end

  describe "Occurrence struct handling" do
    test "handles ci.run.started" do
      run_id = "occ_struct_#{System.unique_integer()}"

      occ = Occurrence.run_started(run_id, "/occ/project", ["build", "test"])
      GenServer.cast(Coordinator, {:occurrence, occ})
      sync_coordinator()

      run = Coordinator.get_run(run_id)
      assert run.id == run_id
      assert run.project_path == "/occ/project"
      assert run.tasks == ["build", "test"]

      # Clean up
      cleanup = Occurrence.run_completed(run_id, :ok)
      GenServer.cast(Coordinator, {:occurrence, cleanup})
    end

    test "handles ci.run.passed → moves to history" do
      run_id = "occ_complete_#{System.unique_integer()}"

      start_occ = Occurrence.run_started(run_id, "/complete/project", ["task"])
      GenServer.cast(Coordinator, {:occurrence, start_occ})
      sync_coordinator()

      complete_occ = Occurrence.run_completed(run_id, :ok)
      GenServer.cast(Coordinator, {:occurrence, complete_occ})
      sync_coordinator()

      assert Coordinator.get_run(run_id) == nil ||
               Coordinator.get_run(run_id).status == :completed

      history = Coordinator.run_history()
      assert Enum.any?(history, fn r -> r.id == run_id end)
    end

    test "handles ci.run.failed" do
      run_id = "occ_fail_#{System.unique_integer()}"

      start_occ = Occurrence.run_started(run_id, "/fail/project", ["task"])
      GenServer.cast(Coordinator, {:occurrence, start_occ})
      sync_coordinator()

      fail_occ = Occurrence.run_completed(run_id, {:error, :task_failed})
      GenServer.cast(Coordinator, {:occurrence, fail_occ})
      sync_coordinator()

      history = Coordinator.run_history()
      failed_run = Enum.find(history, fn r -> r.id == run_id end)
      assert failed_run.status == :failed
    end
  end
end
