defmodule Sykli.Verify.PlannerTest do
  use ExUnit.Case, async: true

  alias Sykli.Verify.Planner
  alias Sykli.RunHistory.{Run, TaskResult}
  alias Sykli.Graph

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp make_run(task_results) do
    %Run{
      id: "test-run-1",
      timestamp: DateTime.utc_now(),
      git_ref: "abc123",
      git_branch: "main",
      tasks: task_results,
      overall: :passed
    }
  end

  defp make_task_result(name, opts \\ []) do
    %TaskResult{
      name: name,
      status: Keyword.get(opts, :status, :passed),
      duration_ms: Keyword.get(opts, :duration_ms, 100),
      cached: Keyword.get(opts, :cached, false)
    }
  end

  defp make_graph_task(name, opts \\ []) do
    %Graph.Task{
      name: name,
      command: Keyword.get(opts, :command, "echo ok"),
      verify: Keyword.get(opts, :verify, nil)
    }
  end

  defp tasks_map(tasks) do
    Map.new(tasks, fn t -> {t.name, t} end)
  end

  defp mac_labels, do: ["darwin", "arm64"]
  defp linux_node, do: %{node: :worker@linux, labels: ["linux", "amd64"]}
  defp mac_node, do: %{node: :worker@mac2, labels: ["darwin", "arm64"]}

  # ── Tests ────────────────────────────────────────────────────────────────────

  describe "plan/4 with no remote nodes" do
    test "skips all tasks when no remote nodes available" do
      run = make_run([make_task_result("build"), make_task_result("test")])
      tasks = tasks_map([make_graph_task("build"), make_graph_task("test")])

      plan = Planner.plan(run, tasks, mac_labels(), [])

      assert plan.entries == []
      assert length(plan.skipped) == 2
      assert {"build", :no_remote_nodes} in plan.skipped
      assert {"test", :no_remote_nodes} in plan.skipped
    end
  end

  describe "plan/4 skipping cached tasks" do
    test "skips cached tasks" do
      run = make_run([make_task_result("build", cached: true)])
      tasks = tasks_map([make_graph_task("build")])

      plan = Planner.plan(run, tasks, mac_labels(), [linux_node()])

      assert plan.entries == []
      assert [{"build", :cached}] = plan.skipped
    end
  end

  describe "plan/4 skipping previously-skipped tasks" do
    test "skips tasks that were skipped in the run" do
      run = make_run([make_task_result("lint", status: :skipped)])
      tasks = tasks_map([make_graph_task("lint")])

      plan = Planner.plan(run, tasks, mac_labels(), [linux_node()])

      assert plan.entries == []
      assert [{"lint", :skipped}] = plan.skipped
    end
  end

  describe "plan/4 with verify: never" do
    test "skips tasks with verify set to never" do
      run = make_run([make_task_result("build")])
      tasks = tasks_map([make_graph_task("build", verify: "never")])

      plan = Planner.plan(run, tasks, mac_labels(), [linux_node()])

      assert plan.entries == []
      assert [{"build", :verify_never}] = plan.skipped
    end
  end

  describe "plan/4 with verify: always" do
    test "dispatches to any remote node regardless of platform" do
      run = make_run([make_task_result("deploy")])
      tasks = tasks_map([make_graph_task("deploy", verify: "always")])

      plan = Planner.plan(run, tasks, mac_labels(), [mac_node()])

      assert length(plan.entries) == 1
      [entry] = plan.entries
      assert entry.task_name == "deploy"
      assert entry.target_node == :worker@mac2
      assert entry.reason == :explicit_verify
    end
  end

  describe "plan/4 with verify: cross_platform" do
    test "dispatches to node with different OS/arch" do
      run = make_run([make_task_result("build")])
      tasks = tasks_map([make_graph_task("build", verify: "cross_platform")])

      plan = Planner.plan(run, tasks, mac_labels(), [linux_node()])

      assert length(plan.entries) == 1
      [entry] = plan.entries
      assert entry.task_name == "build"
      assert entry.target_node == :worker@linux
      assert entry.target_labels == ["linux", "amd64"]
      assert entry.reason == :cross_platform
    end

    test "skips when all remotes have same platform" do
      run = make_run([make_task_result("build")])
      tasks = tasks_map([make_graph_task("build", verify: "cross_platform")])

      plan = Planner.plan(run, tasks, mac_labels(), [mac_node()])

      assert plan.entries == []
      assert [{"build", :same_platform}] = plan.skipped
    end
  end

  describe "plan/4 with failed tasks" do
    test "retries failed task on different platform node" do
      run = make_run([make_task_result("test", status: :failed)])
      tasks = tasks_map([make_graph_task("test")])

      plan = Planner.plan(run, tasks, mac_labels(), [linux_node()])

      assert length(plan.entries) == 1
      [entry] = plan.entries
      assert entry.task_name == "test"
      assert entry.target_node == :worker@linux
      assert entry.reason == :retry_on_different_platform
    end

    test "retries failed task on same-platform remote when no different platform exists" do
      run = make_run([make_task_result("test", status: :failed)])
      tasks = tasks_map([make_graph_task("test")])

      plan = Planner.plan(run, tasks, mac_labels(), [mac_node()])

      assert length(plan.entries) == 1
      [entry] = plan.entries
      assert entry.task_name == "test"
      assert entry.target_node == :worker@mac2
      assert entry.reason == :retry_on_different_platform
    end
  end

  describe "plan/4 default behavior (no verify mode set)" do
    test "dispatches when a different platform node exists" do
      run = make_run([make_task_result("build")])
      tasks = tasks_map([make_graph_task("build")])

      plan = Planner.plan(run, tasks, mac_labels(), [linux_node()])

      assert length(plan.entries) == 1
      [entry] = plan.entries
      assert entry.task_name == "build"
      assert entry.reason == :cross_platform
    end

    test "skips when all remotes have same platform" do
      run = make_run([make_task_result("build")])
      tasks = tasks_map([make_graph_task("build")])

      plan = Planner.plan(run, tasks, mac_labels(), [mac_node()])

      assert plan.entries == []
      assert [{"build", :same_platform}] = plan.skipped
    end
  end

  describe "plan/4 with mixed tasks" do
    test "handles mixed results correctly" do
      run =
        make_run([
          make_task_result("lint", cached: true),
          make_task_result("test", status: :failed),
          make_task_result("build"),
          make_task_result("deploy", status: :skipped)
        ])

      tasks =
        tasks_map([
          make_graph_task("lint"),
          make_graph_task("test"),
          make_graph_task("build", verify: "never"),
          make_graph_task("deploy")
        ])

      plan = Planner.plan(run, tasks, mac_labels(), [linux_node()])

      # lint: skipped (cached)
      # test: verify (failed → retry on different platform)
      # build: skipped (verify: never)
      # deploy: skipped (was skipped in run)
      assert length(plan.entries) == 1
      assert length(plan.skipped) == 3

      [entry] = plan.entries
      assert entry.task_name == "test"
      assert entry.reason == :retry_on_different_platform

      skip_names = Enum.map(plan.skipped, &elem(&1, 0))
      assert "lint" in skip_names
      assert "build" in skip_names
      assert "deploy" in skip_names
    end
  end

  describe "plan/4 with task not in graph" do
    test "skips tasks that no longer exist in the graph" do
      run = make_run([make_task_result("removed_task")])
      tasks = tasks_map([])

      plan = Planner.plan(run, tasks, mac_labels(), [linux_node()])

      assert plan.entries == []
      assert [{"removed_task", :task_not_found}] = plan.skipped
    end
  end

  describe "plan/4 metadata" do
    test "includes local_labels and remote_nodes in plan" do
      run = make_run([])
      tasks = tasks_map([])
      remote = [linux_node()]

      plan = Planner.plan(run, tasks, mac_labels(), remote)

      assert plan.local_labels == mac_labels()
      assert plan.remote_nodes == remote
    end
  end

  describe "plan/4 preserves task order" do
    test "entries maintain run task order" do
      run =
        make_run([
          make_task_result("alpha"),
          make_task_result("beta"),
          make_task_result("gamma")
        ])

      tasks =
        tasks_map([
          make_graph_task("alpha"),
          make_graph_task("beta"),
          make_graph_task("gamma")
        ])

      plan = Planner.plan(run, tasks, mac_labels(), [linux_node()])

      entry_names = Enum.map(plan.entries, & &1.task_name)
      assert entry_names == ["alpha", "beta", "gamma"]
    end
  end

  describe "find_different_platform_node/2" do
    test "finds linux node from darwin" do
      node = Planner.find_different_platform_node(["darwin", "arm64"], [linux_node()])
      assert node.node == :worker@linux
    end

    test "returns nil when all nodes have same platform" do
      assert nil == Planner.find_different_platform_node(["darwin", "arm64"], [mac_node()])
    end

    test "finds first different-platform node" do
      nodes = [mac_node(), linux_node()]
      node = Planner.find_different_platform_node(["darwin", "arm64"], nodes)
      assert node.node == :worker@linux
    end

    test "ignores non-platform labels" do
      local = ["darwin", "arm64", "gpu", "docker"]
      remote = %{node: :worker@other, labels: ["darwin", "arm64", "ssd"]}
      assert nil == Planner.find_different_platform_node(local, [remote])
    end
  end
end
