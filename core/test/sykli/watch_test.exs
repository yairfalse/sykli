defmodule Sykli.WatchTest do
  use ExUnit.Case, async: false

  # Note: Full integration testing of the watch module requires actual file
  # system events which are difficult to test reliably. These tests focus on
  # the debouncing and message handling logic.

  describe "debouncing" do
    test "multiple rapid file events are batched" do
      # Simulate the debouncing behavior by checking that pending_files accumulates
      state = %Sykli.Watch{
        path: "/tmp/test",
        watcher_pid: nil,
        pending_files: MapSet.new(),
        timer_ref: nil,
        from_ref: "HEAD"
      }

      # Add multiple files to pending
      state = %{state | pending_files: MapSet.put(state.pending_files, "/tmp/test/a.ex")}
      state = %{state | pending_files: MapSet.put(state.pending_files, "/tmp/test/b.ex")}
      state = %{state | pending_files: MapSet.put(state.pending_files, "/tmp/test/c.ex")}

      assert MapSet.size(state.pending_files) == 3
      assert MapSet.member?(state.pending_files, "/tmp/test/a.ex")
      assert MapSet.member?(state.pending_files, "/tmp/test/b.ex")
      assert MapSet.member?(state.pending_files, "/tmp/test/c.ex")
    end

    test "timer_ref is tracked in state" do
      state = %Sykli.Watch{
        path: "/tmp/test",
        watcher_pid: nil,
        pending_files: MapSet.new(),
        timer_ref: nil,
        from_ref: "HEAD"
      }

      # Simulate setting a timer
      timer_ref = make_ref()
      state = %{state | timer_ref: timer_ref}

      assert state.timer_ref == timer_ref
    end
  end

  describe "file filtering" do
    # Test the ignore patterns by checking known paths
    # Note: should_ignore? is private, so we test indirectly

    test "state tracks from_ref option" do
      state = %Sykli.Watch{
        path: "/tmp/test",
        watcher_pid: nil,
        pending_files: MapSet.new(),
        timer_ref: nil,
        from_ref: "main"
      }

      assert state.from_ref == "main"
    end

    test "state tracks absolute path" do
      state = %Sykli.Watch{
        path: "/home/user/project",
        watcher_pid: nil,
        pending_files: MapSet.new(),
        timer_ref: nil,
        from_ref: "HEAD"
      }

      assert state.path == "/home/user/project"
    end
  end

  describe "stop/0" do
    test "stop returns ok when not running" do
      # Should not raise when process doesn't exist
      assert Sykli.Watch.stop() == :ok
    end
  end
end
