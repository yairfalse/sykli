defmodule Sykli.Executor.ServerTest do
  use ExUnit.Case, async: false

  alias Sykli.Executor.Server
  alias Sykli.Events
  alias Sykli.Events.Event
  alias Sykli.RunRegistry

  describe "execute/4" do
    test "returns run_id immediately" do
      task = %Sykli.Graph.Task{
        name: "fast_task",
        command: "echo hello",
        depends_on: []
      }
      graph = %{"fast_task" => task}

      {:ok, run_id} = Server.execute("/tmp", [task], graph)

      assert is_binary(run_id)
      assert String.length(run_id) > 0
    end

    test "emits run_started event" do
      Events.subscribe(:all)

      task = %Sykli.Graph.Task{
        name: "event_task",
        command: "echo test",
        depends_on: []
      }
      graph = %{"event_task" => task}

      {:ok, run_id} = Server.execute("/tmp", [task], graph)

      assert_receive %Event{
        type: :run_started,
        run_id: ^run_id,
        data: %{tasks: ["event_task"]}
      }, 1000
    end

    test "emits task_started and task_completed events" do
      Events.subscribe(:all)

      task = %Sykli.Graph.Task{
        name: "traced_task",
        command: "echo traced",
        depends_on: []
      }
      graph = %{"traced_task" => task}

      {:ok, run_id} = Server.execute("/tmp", [task], graph)

      assert_receive %Event{type: :task_started, run_id: ^run_id, data: %{task_name: "traced_task"}}, 1000
      assert_receive %Event{type: :task_completed, run_id: ^run_id, data: %{task_name: "traced_task"}}, 1000
    end

    test "emits run_completed event" do
      Events.subscribe(:all)

      task = %Sykli.Graph.Task{
        name: "complete_task",
        command: "echo done",
        depends_on: []
      }
      graph = %{"complete_task" => task}

      {:ok, run_id} = Server.execute("/tmp", [task], graph)

      assert_receive %Event{type: :run_completed, run_id: ^run_id}, 2000
    end

    test "registers run with RunRegistry" do
      task = %Sykli.Graph.Task{
        name: "registry_task",
        command: "echo registry",
        depends_on: []
      }
      graph = %{"registry_task" => task}

      {:ok, run_id} = Server.execute("/tmp", [task], graph)

      # Give it a moment to register
      Process.sleep(10)

      {:ok, run} = RunRegistry.get_run(run_id)
      assert run.project_path == "/tmp"
      assert "registry_task" in run.tasks
    end
  end

  describe "execute_sync/4" do
    test "waits for completion and returns results" do
      task = %Sykli.Graph.Task{
        name: "sync_task",
        command: "echo sync",
        depends_on: []
      }
      graph = %{"sync_task" => task}

      result = Server.execute_sync("/tmp", [task], graph)

      assert {:ok, run_id, run_result} = result
      assert is_binary(run_id)
      # run_result is the run's result field (:ok on success)
      assert run_result == :ok
    end

    test "returns error for failed task" do
      task = %Sykli.Graph.Task{
        name: "fail_task",
        command: "exit 1",
        depends_on: []
      }
      graph = %{"fail_task" => task}

      result = Server.execute_sync("/tmp", [task], graph)

      assert {:error, _run_id, :task_failed} = result
    end

    test "respects configurable timeout" do
      # Timeout is configurable via Application.get_env(:sykli, :executor_sync_timeout)
      # Default is 10 minutes (600_000ms), which we won't actually test waiting for
      # Just verify it doesn't crash with a quick task

      task = %Sykli.Graph.Task{
        name: "quick_task",
        command: "echo quick",
        depends_on: []
      }
      graph = %{"quick_task" => task}

      result = Server.execute_sync("/tmp", [task], graph)

      assert {:ok, _, _} = result
    end
  end

  describe "get_status/1" do
    test "returns run information from registry" do
      task = %Sykli.Graph.Task{
        name: "status_task",
        command: "echo status",
        depends_on: []
      }
      graph = %{"status_task" => task}

      {:ok, run_id} = Server.execute("/tmp", [task], graph)

      # Wait for run to complete
      Process.sleep(100)

      result = Server.get_status(run_id)

      assert {:ok, run} = result
      # Run struct uses :id not :run_id
      assert run.id == run_id
    end

    test "returns error for unknown run" do
      result = Server.get_status("nonexistent_run_id")

      assert {:error, :not_found} = result
    end
  end

  describe "parallel execution" do
    test "executes independent tasks in parallel" do
      Events.subscribe(:all)

      task1 = %Sykli.Graph.Task{name: "parallel_a", command: "echo a", depends_on: []}
      task2 = %Sykli.Graph.Task{name: "parallel_b", command: "echo b", depends_on: []}

      graph = %{
        "parallel_a" => task1,
        "parallel_b" => task2
      }

      {:ok, run_id} = Server.execute("/tmp", [task1, task2], graph)

      # Both tasks should start (they're at the same level)
      assert_receive %Event{type: :task_started, run_id: ^run_id, data: %{task_name: name1}}, 1000
      assert_receive %Event{type: :task_started, run_id: ^run_id, data: %{task_name: name2}}, 1000

      # Verify both names were received (order may vary)
      assert MapSet.new([name1, name2]) == MapSet.new(["parallel_a", "parallel_b"])
    end
  end

  describe "task with no command" do
    test "succeeds for task without command" do
      task = %Sykli.Graph.Task{
        name: "no_command_task",
        command: nil,
        depends_on: []
      }
      graph = %{"no_command_task" => task}

      result = Server.execute_sync("/tmp", [task], graph)

      assert {:ok, _, _} = result
    end
  end

  describe "crash handling" do
    test "handles execution errors gracefully" do
      Events.subscribe(:all)

      # A task with invalid command that might cause issues
      task = %Sykli.Graph.Task{
        name: "bad_cmd",
        command: "nonexistent_command_xyz_123",
        depends_on: []
      }
      graph = %{"bad_cmd" => task}

      {:ok, run_id} = Server.execute("/tmp", [task], graph)

      # Should complete (with failure) rather than crash
      assert_receive %Event{type: :run_completed, run_id: ^run_id}, 2000
    end
  end
end
