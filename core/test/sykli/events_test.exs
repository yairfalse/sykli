defmodule Sykli.EventsTest do
  use ExUnit.Case, async: false

  alias Sykli.Events
  alias Sykli.Events.Event

  describe "subscribe/1" do
    test "subscribes to specific run events" do
      run_id = "test_run_123"
      Events.subscribe(run_id)

      Events.task_started(run_id, "test_task")

      assert_receive %Event{type: :task_started, run_id: ^run_id, data: %{task_name: "test_task"}}
    end

    test "subscribes to all events with :all" do
      Events.subscribe(:all)

      run_id1 = "run_1"
      run_id2 = "run_2"

      Events.task_started(run_id1, "task_a")
      Events.task_started(run_id2, "task_b")

      assert_receive %Event{type: :task_started, run_id: ^run_id1, data: %{task_name: "task_a"}}
      assert_receive %Event{type: :task_started, run_id: ^run_id2, data: %{task_name: "task_b"}}
    end
  end

  describe "run_started/3" do
    test "broadcasts run started event" do
      Events.subscribe(:all)

      run_id = "run_456"
      Events.run_started(run_id, "/path/to/project", ["test", "build"])

      assert_receive %Event{
        type: :run_started,
        run_id: ^run_id,
        data: %{project_path: "/path/to/project", tasks: ["test", "build"]}
      }
    end
  end

  describe "task_completed/3" do
    test "broadcasts success result" do
      Events.subscribe(:all)

      run_id = "run_789"
      Events.task_completed(run_id, "test", :ok)

      assert_receive %Event{
        type: :task_completed,
        run_id: ^run_id,
        data: %{task_name: "test", outcome: :success}
      }
    end

    test "broadcasts error result" do
      Events.subscribe(:all)

      run_id = "run_error"
      Events.task_completed(run_id, "build", {:error, :compilation_failed})

      assert_receive %Event{
        type: :task_completed,
        run_id: ^run_id,
        data: %{task_name: "build", outcome: :failure, error: :compilation_failed}
      }
    end
  end

  describe "run_completed/2" do
    test "broadcasts run completion" do
      Events.subscribe(:all)

      run_id = "run_complete"
      Events.run_completed(run_id, :ok)

      assert_receive %Event{
        type: :run_completed,
        run_id: ^run_id,
        data: %{outcome: :success}
      }
    end
  end

  describe "unsubscribe/1" do
    test "stops receiving events after unsubscribe" do
      run_id = "run_unsub"
      Events.subscribe(run_id)

      Events.task_started(run_id, "before")
      assert_receive %Event{type: :task_started, run_id: ^run_id, data: %{task_name: "before"}}

      Events.unsubscribe(run_id)

      Events.task_started(run_id, "after")
      refute_receive %Event{type: :task_started, run_id: ^run_id}, 100
    end
  end

  describe "Event struct" do
    test "has ULID id" do
      Events.subscribe(:all)

      Events.task_started("run_ulid", "task")

      assert_receive %Event{id: id} when is_binary(id) and byte_size(id) == 26
    end

    test "includes node information" do
      Events.subscribe(:all)

      Events.task_started("run_node", "task")

      assert_receive %Event{node: node} when is_atom(node)
    end

    test "has timestamp" do
      Events.subscribe(:all)

      Events.task_started("run_ts", "task")

      assert_receive %Event{timestamp: %DateTime{}}
    end
  end
end
