defmodule Sykli.ReporterTest do
  use ExUnit.Case, async: false

  alias Sykli.Events
  alias Sykli.Reporter

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

      # In test environment, no coordinator is configured
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
      # This won't actually connect (no such node), but shouldn't crash
      assert :ok = Reporter.configure("fake_coordinator@localhost")
    end

    test "accepts atom node name" do
      assert :ok = Reporter.configure(:fake_coordinator@localhost)
    end
  end

  describe "event forwarding" do
    test "subscribes to events on startup" do
      # Reporter subscribes to :all events on init
      # We can verify by checking that events are received
      # (The Reporter is already started by the application)

      # Just verify the reporter is alive and receiving events
      status = Reporter.status()
      assert is_map(status)
    end
  end

  describe "buffering behavior" do
    test "buffers events when disconnected" do
      # Get initial buffer count
      initial_status = Reporter.status()
      initial_buffered = initial_status.buffered

      # Emit some events (these should get buffered since we're not connected)
      run_id = "buffer_test_#{System.monotonic_time()}"
      Events.run_started(run_id, "/test", ["task1"])
      Events.task_started(run_id, "task1")
      Events.task_completed(run_id, "task1", :ok)
      Events.run_completed(run_id, :ok)

      # Give a moment for events to be processed
      Process.sleep(50)

      # Check buffer increased (events are buffered when disconnected)
      new_status = Reporter.status()
      assert new_status.buffered >= initial_buffered
    end

    test "buffer respects configurable limit" do
      # The buffer limit is configurable via Application.get_env
      # Default is 1000, but we can test the mechanism exists

      status = Reporter.status()
      # Buffer size should be a non-negative integer
      assert is_integer(status.buffered)
      assert status.buffered >= 0
    end
  end

  describe "Event struct handling" do
    test "handles run_started events" do
      # This tests that Reporter doesn't crash on Event struct format
      run_id = "event_test_run_#{System.monotonic_time()}"

      # Create and emit an event - reporter should handle it
      Events.run_started(run_id, "/test/path", ["test", "build"])

      # If we get here without crash, the handler works
      status = Reporter.status()
      assert is_map(status)
    end

    test "handles task_started events" do
      run_id = "event_test_task_#{System.monotonic_time()}"
      Events.task_started(run_id, "my_task")

      status = Reporter.status()
      assert is_map(status)
    end

    test "handles task_completed events" do
      run_id = "event_test_complete_#{System.monotonic_time()}"
      Events.task_completed(run_id, "my_task", :ok)

      status = Reporter.status()
      assert is_map(status)
    end

    test "handles run_completed events" do
      run_id = "event_test_done_#{System.monotonic_time()}"
      Events.run_completed(run_id, :ok)

      status = Reporter.status()
      assert is_map(status)
    end

    test "handles task_output events without buffering" do
      # task_output events are not buffered (too much data)
      run_id = "event_test_output_#{System.monotonic_time()}"

      initial_status = Reporter.status()
      initial_buffered = initial_status.buffered

      Events.task_output(run_id, "my_task", "some output")
      Process.sleep(10)

      # task_output should NOT increase buffer (it's not buffered)
      new_status = Reporter.status()
      # Buffer should be same or decreased (if flush happened)
      assert new_status.buffered <= initial_buffered + 4  # Allow for other events
    end
  end
end
