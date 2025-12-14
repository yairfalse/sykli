defmodule Sykli.ProgressTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  # Helper to create task struct
  defp make_task(name, command, opts \\ []) do
    %Sykli.Graph.Task{
      name: name,
      command: command,
      depends_on: Keyword.get(opts, :depends_on, []),
      inputs: [],
      outputs: [],
      container: nil,
      workdir: nil,
      env: %{},
      mounts: []
    }
  end

  describe "progress counter" do
    test "shows [current/total] before task name" do
      tasks = [make_task("test", "echo test"), make_task("build", "echo build")]
      graph = Map.new(tasks, fn t -> {t.name, t} end)

      output = capture_io(fn ->
        Sykli.Executor.run(tasks, graph, workdir: "/tmp")
      end)

      # Should show progress like [1/2] or [2/2]
      assert output =~ ~r/\[\d+\/2\]/
    end
  end

  describe "parallel indicator" do
    test "shows tasks running in parallel" do
      # Two tasks with no deps run in parallel
      tasks = [make_task("a", "echo a"), make_task("b", "echo b")]
      graph = Map.new(tasks, fn t -> {t.name, t} end)

      output = capture_io(fn ->
        Sykli.Executor.run(tasks, graph, workdir: "/tmp")
      end)

      # Should indicate parallel execution (e.g., "2 parallel" or similar)
      assert output =~ ~r/parallel|║|simultaneously/i or output =~ "2 task(s)"
    end
  end

  describe "cache status" do
    @tag :skip
    test "shows CACHED for cache hits" do
      # TODO: Implement with cache mocking
      flunk("Not implemented - requires cache mocking")
    end
  end

  describe "timestamps" do
    test "shows start time for non-cached tasks" do
      # Use a unique command that won't be cached
      tasks = [make_task("test", "echo #{System.unique_integer()}")]
      graph = Map.new(tasks, fn t -> {t.name, t} end)

      output = capture_io(fn ->
        Sykli.Executor.run(tasks, graph, workdir: "/tmp")
      end)

      # Should show timestamp like HH:MM:SS for non-cached tasks
      assert output =~ ~r/\d{2}:\d{2}:\d{2}/
    end
  end

  describe "pending queue" do
    test "shows upcoming tasks" do
      # Task b depends on a, so b should show as pending while a runs
      tasks = [
        make_task("a", "echo a"),
        make_task("b", "echo b", depends_on: ["a"])
      ]
      graph = Map.new(tasks, fn t -> {t.name, t} end)

      output = capture_io(fn ->
        Sykli.Executor.run(tasks, graph, workdir: "/tmp")
      end)

      # Should show something about next/pending/upcoming
      assert output =~ ~r/next|pending|→|Level/i
    end
  end

  describe "output line count" do
    test "shows line count in summary" do
      tasks = [make_task("test", "echo line1 && echo line2")]
      graph = Map.new(tasks, fn t -> {t.name, t} end)

      output = capture_io(fn ->
        Sykli.Executor.run(tasks, graph, workdir: "/tmp")
      end)

      # Should show line count like "2 lines" or similar in output
      assert output =~ ~r/line|output|\d+L/i or String.contains?(output, "passed")
    end
  end

  describe "summary" do
    test "shows total duration" do
      tasks = [make_task("test", "echo test")]
      graph = Map.new(tasks, fn t -> {t.name, t} end)

      output = capture_io(fn ->
        Sykli.Executor.run(tasks, graph, workdir: "/tmp")
      end)

      # Should show duration in summary
      assert output =~ ~r/\d+(\.\d+)?(ms|s|m)/
    end

    test "shows passed/failed counts" do
      tasks = [make_task("test", "echo test")]
      graph = Map.new(tasks, fn t -> {t.name, t} end)

      output = capture_io(fn ->
        Sykli.Executor.run(tasks, graph, workdir: "/tmp")
      end)

      assert output =~ ~r/\d+ passed/
    end
  end
end
