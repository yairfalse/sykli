defmodule Sykli.TimeoutTest do
  use ExUnit.Case, async: false

  alias Sykli.Runtime.Shell
  alias Sykli.Target.Local

  describe "Shell runtime timeout" do
    test "kills process when timeout fires" do
      start = System.monotonic_time(:millisecond)
      result = Shell.run("sleep 30", nil, [], workdir: ".", timeout_ms: 1000)
      elapsed = System.monotonic_time(:millisecond) - start

      assert {:error, :timeout} = result
      assert elapsed < 3000, "should complete in ~1s, took #{elapsed}ms"
    end

    test "normal command completes before timeout" do
      result = Shell.run("echo hello", nil, [], workdir: ".", timeout_ms: 5000)
      assert {:ok, 0, _lines, output} = result
      assert output =~ "hello"
    end

    test "process is actually killed after timeout" do
      # Start a command that writes a marker file after 5s
      marker = "/tmp/sykli_timeout_test_marker_#{:rand.uniform(100_000)}"
      File.rm(marker)

      _result =
        Shell.run(
          "sleep 2 && touch #{marker}",
          nil,
          [],
          workdir: ".",
          timeout_ms: 500
        )

      # Wait for the would-be marker creation
      Process.sleep(3000)

      # Marker should NOT exist if process was properly killed
      refute File.exists?(marker), "process was not killed — marker file was created"
    after
      "/tmp/sykli_timeout_test_marker_*"
      |> Path.wildcard()
      |> Enum.each(&File.rm/1)
    end
  end

  describe "Local target timeout" do
    test "task-level timeout from task.timeout field" do
      {:ok, state} = Local.setup(workdir: "/tmp")

      task =
        struct!(Sykli.Graph.Task, %{
          name: "slow",
          command: "sleep 30",
          timeout: 1
        })

      start = System.monotonic_time(:millisecond)
      result = Local.run_task(task, state, [])
      elapsed = System.monotonic_time(:millisecond) - start

      assert {:error, %Sykli.Error{code: "task_timeout"}} = result
      assert elapsed < 3000
    end

    test "global timeout from --timeout flag" do
      {:ok, state} = Local.setup(workdir: "/tmp", timeout: 1000)

      task = struct!(Sykli.Graph.Task, %{name: "slow", command: "sleep 30"})

      start = System.monotonic_time(:millisecond)
      result = Local.run_task(task, state, [])
      elapsed = System.monotonic_time(:millisecond) - start

      assert {:error, %Sykli.Error{code: "task_timeout"}} = result
      assert elapsed < 3000
    end

    test "task-specific timeout takes precedence over global" do
      {:ok, state} = Local.setup(workdir: "/tmp", timeout: 30_000)

      # Task timeout of 1 second should override global 30s
      task =
        struct!(Sykli.Graph.Task, %{
          name: "slow",
          command: "sleep 30",
          timeout: 1
        })

      start = System.monotonic_time(:millisecond)
      result = Local.run_task(task, state, [])
      elapsed = System.monotonic_time(:millisecond) - start

      assert {:error, %Sykli.Error{code: "task_timeout"}} = result
      assert elapsed < 3000
    end
  end

  describe "Docker runtime timeout" do
    @tag :docker
    test "kills container when timeout fires" do
      case Sykli.Runtime.Docker.available?() do
        {:ok, _} ->
          start = System.monotonic_time(:millisecond)

          result =
            Sykli.Runtime.Docker.run(
              "sleep 30",
              "alpine:latest",
              [],
              workdir: ".",
              timeout_ms: 2000
            )

          elapsed = System.monotonic_time(:millisecond) - start

          assert {:error, :timeout} = result
          # Allow extra time for Docker image pull on first run
          assert elapsed < 15000

        {:error, _} ->
          :skip
      end
    end
  end
end
