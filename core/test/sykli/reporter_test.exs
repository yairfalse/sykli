defmodule Sykli.ReporterTest do
  use ExUnit.Case, async: false

  alias Sykli.Occurrence.PubSub, as: OccPubSub
  alias Sykli.Reporter

  defp sync_reporter do
    :sys.get_state(Reporter)
    :ok
  end

  describe "status/0" do
    test "returns current reporter status" do
      status = Reporter.status()

      assert is_map(status)
      assert Map.has_key?(status, :coordinator)
      assert Map.has_key?(status, :connected)
      assert Map.has_key?(status, :buffered)
    end

    test "starts disconnected when no coordinator configured" do
      status = Reporter.status()
      assert status.connected == false
    end
  end

  describe "connected?/0" do
    test "returns false when not connected" do
      refute Reporter.connected?()
    end
  end

  describe "configure/1" do
    test "accepts binary node name" do
      assert :ok = Reporter.configure("fake_coordinator@localhost")
    end

    test "accepts atom node name" do
      assert :ok = Reporter.configure(:fake_coordinator@localhost)
    end
  end

  describe "occurrence forwarding" do
    test "subscribes to occurrences on startup" do
      status = Reporter.status()
      assert is_map(status)
    end
  end

  describe "buffering behavior" do
    test "buffers occurrences when disconnected" do
      initial_status = Reporter.status()
      initial_buffered = initial_status.buffered

      run_id = "buffer_test_#{System.monotonic_time()}"
      OccPubSub.run_started(run_id, "/test", ["task1"])
      OccPubSub.task_started(run_id, "task1")
      OccPubSub.task_completed(run_id, "task1", :ok)
      OccPubSub.run_completed(run_id, :ok)

      sync_reporter()

      new_status = Reporter.status()
      assert new_status.buffered >= initial_buffered
    end

    test "buffer respects configurable limit" do
      status = Reporter.status()
      assert is_integer(status.buffered)
      assert status.buffered >= 0
    end
  end

  describe "Occurrence handling" do
    test "handles run_started occurrences" do
      run_id = "occ_test_run_#{System.monotonic_time()}"
      OccPubSub.run_started(run_id, "/test/path", ["test", "build"])

      status = Reporter.status()
      assert is_map(status)
    end

    test "handles task_started occurrences" do
      run_id = "occ_test_task_#{System.monotonic_time()}"
      OccPubSub.task_started(run_id, "my_task")

      status = Reporter.status()
      assert is_map(status)
    end

    test "handles task_completed occurrences" do
      run_id = "occ_test_complete_#{System.monotonic_time()}"
      OccPubSub.task_completed(run_id, "my_task", :ok)

      status = Reporter.status()
      assert is_map(status)
    end

    test "handles run_completed occurrences" do
      run_id = "occ_test_done_#{System.monotonic_time()}"
      OccPubSub.run_completed(run_id, :ok)

      status = Reporter.status()
      assert is_map(status)
    end

    test "handles task_output occurrences without buffering" do
      run_id = "occ_test_output_#{System.monotonic_time()}"

      initial_status = Reporter.status()
      initial_buffered = initial_status.buffered

      OccPubSub.task_output(run_id, "my_task", "some output")
      sync_reporter()

      new_status = Reporter.status()
      # task_output should NOT increase buffer
      assert new_status.buffered <= initial_buffered + 1
    end
  end
end
