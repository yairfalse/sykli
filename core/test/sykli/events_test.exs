defmodule Sykli.EventsTest do
  use ExUnit.Case, async: false

  alias Sykli.Events

  describe "subscribe/1" do
    test "subscribes to specific run events" do
      run_id = "test_run_123"
      Events.subscribe(run_id)

      Events.task_started(run_id, "test_task")

      assert_receive {:task_started, ^run_id, "test_task"}
    end

    test "subscribes to all events with :all" do
      Events.subscribe(:all)

      run_id1 = "run_1"
      run_id2 = "run_2"

      Events.task_started(run_id1, "task_a")
      Events.task_started(run_id2, "task_b")

      assert_receive {:task_started, ^run_id1, "task_a"}
      assert_receive {:task_started, ^run_id2, "task_b"}
    end
  end

  describe "run_started/3" do
    test "broadcasts run started event" do
      Events.subscribe(:all)

      run_id = "run_456"
      Events.run_started(run_id, "/path/to/project", ["test", "build"])

      assert_receive {:run_started, ^run_id, "/path/to/project", ["test", "build"]}
    end
  end

  describe "task_completed/3" do
    test "broadcasts success result" do
      Events.subscribe(:all)

      run_id = "run_789"
      Events.task_completed(run_id, "test", :ok)

      assert_receive {:task_completed, ^run_id, "test", :ok}
    end

    test "broadcasts error result" do
      Events.subscribe(:all)

      run_id = "run_error"
      Events.task_completed(run_id, "build", {:error, :compilation_failed})

      assert_receive {:task_completed, ^run_id, "build", {:error, :compilation_failed}}
    end
  end

  describe "run_completed/2" do
    test "broadcasts run completion" do
      Events.subscribe(:all)

      run_id = "run_complete"
      Events.run_completed(run_id, :ok)

      assert_receive {:run_completed, ^run_id, :ok}
    end
  end

  describe "unsubscribe/1" do
    test "stops receiving events after unsubscribe" do
      run_id = "run_unsub"
      Events.subscribe(run_id)

      Events.task_started(run_id, "before")
      assert_receive {:task_started, ^run_id, "before"}

      Events.unsubscribe(run_id)

      Events.task_started(run_id, "after")
      refute_receive {:task_started, ^run_id, "after"}, 100
    end
  end
end
