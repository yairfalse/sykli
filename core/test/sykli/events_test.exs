defmodule Sykli.EventsTest do
  use ExUnit.Case, async: false

  alias Sykli.Occurrence
  alias Sykli.Occurrence.PubSub, as: OccPubSub

  describe "subscribe/1" do
    test "subscribes to specific run occurrences" do
      run_id = "test_run_123"
      OccPubSub.subscribe(run_id)

      OccPubSub.task_started(run_id, "test_task")

      assert_receive %Occurrence{
        type: "ci.task.started",
        run_id: ^run_id,
        data: %{task_name: "test_task"}
      }
    end

    test "subscribes to all occurrences with :all" do
      OccPubSub.subscribe(:all)

      run_id1 = "run_1"
      run_id2 = "run_2"

      OccPubSub.task_started(run_id1, "task_a")
      OccPubSub.task_started(run_id2, "task_b")

      assert_receive %Occurrence{
        type: "ci.task.started",
        run_id: ^run_id1,
        data: %{task_name: "task_a"}
      }

      assert_receive %Occurrence{
        type: "ci.task.started",
        run_id: ^run_id2,
        data: %{task_name: "task_b"}
      }
    end
  end

  describe "run_started/3" do
    test "broadcasts run started occurrence" do
      OccPubSub.subscribe(:all)

      run_id = "run_456"
      OccPubSub.run_started(run_id, "/path/to/project", ["test", "build"])

      assert_receive %Occurrence{
        type: "ci.run.started",
        run_id: ^run_id,
        data: %{project_path: "/path/to/project", tasks: ["test", "build"]}
      }
    end
  end

  describe "task_completed/3" do
    test "broadcasts success result" do
      OccPubSub.subscribe(:all)

      run_id = "run_789"
      OccPubSub.task_completed(run_id, "test", :ok)

      assert_receive %Occurrence{
        type: "ci.task.completed",
        run_id: ^run_id,
        data: %{task_name: "test", outcome: :success}
      }
    end

    test "broadcasts error result" do
      OccPubSub.subscribe(:all)

      run_id = "run_error"
      OccPubSub.task_completed(run_id, "build", {:error, :compilation_failed})

      assert_receive %Occurrence{
        type: "ci.task.completed",
        run_id: ^run_id,
        data: %{task_name: "build", outcome: :failure, error: :compilation_failed}
      }
    end
  end

  describe "run_completed/2" do
    test "broadcasts run completion as ci.run.passed" do
      OccPubSub.subscribe(:all)

      run_id = "run_complete"
      OccPubSub.run_completed(run_id, :ok)

      assert_receive %Occurrence{
        type: "ci.run.passed",
        run_id: ^run_id,
        outcome: "success",
        data: %{outcome: :success}
      }
    end

    test "broadcasts run failure as ci.run.failed" do
      OccPubSub.subscribe(:all)

      run_id = "run_fail"
      OccPubSub.run_completed(run_id, {:error, :task_failed})

      assert_receive %Occurrence{
        type: "ci.run.failed",
        run_id: ^run_id,
        outcome: "failure",
        data: %{outcome: :failure}
      }
    end
  end

  describe "unsubscribe/1" do
    test "stops receiving occurrences after unsubscribe" do
      run_id = "run_unsub"
      OccPubSub.subscribe(run_id)

      OccPubSub.task_started(run_id, "before")

      assert_receive %Occurrence{
        type: "ci.task.started",
        run_id: ^run_id,
        data: %{task_name: "before"}
      }

      OccPubSub.unsubscribe(run_id)

      OccPubSub.task_started(run_id, "after")
      refute_receive %Occurrence{type: "ci.task.started", run_id: ^run_id}, 100
    end
  end

  describe "Occurrence struct" do
    test "has ULID id" do
      OccPubSub.subscribe(:all)

      OccPubSub.task_started("run_ulid", "task")

      assert_receive %Occurrence{id: id} when is_binary(id) and byte_size(id) == 26
    end

    test "includes node information" do
      OccPubSub.subscribe(:all)

      OccPubSub.task_started("run_node", "task")

      assert_receive %Occurrence{node: node} when is_atom(node)
    end

    test "has timestamp" do
      OccPubSub.subscribe(:all)

      OccPubSub.task_started("run_ts", "task")

      assert_receive %Occurrence{timestamp: %DateTime{}}
    end

    test "has FALSE Protocol version" do
      OccPubSub.subscribe(:all)

      OccPubSub.task_started("run_ver", "task")

      assert_receive %Occurrence{protocol_version: "1.0"}
    end

    test "has source set to sykli" do
      OccPubSub.subscribe(:all)

      OccPubSub.task_started("run_src", "task")

      assert_receive %Occurrence{source: "sykli"}
    end
  end

  describe "backward compat via Sykli.Events" do
    test "Sykli.Events delegates to PubSub" do
      Sykli.Events.subscribe(:all)

      Sykli.Events.task_started("compat_run", "compat_task")

      assert_receive %Occurrence{
        type: "ci.task.started",
        run_id: "compat_run",
        data: %{task_name: "compat_task"}
      }
    end
  end
end
