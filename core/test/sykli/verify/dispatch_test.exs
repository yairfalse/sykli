defmodule Sykli.Verify.DispatchTest do
  @moduledoc """
  DST-style tests for Verify dispatch & merge.

  These tests inject fake :discover_fn, :labels_fn, and :dispatch_fn into
  Sykli.Verify.verify/1 so we can exercise the full pipeline
  (load → plan → dispatch → merge → save) without a live BEAM cluster.
  """
  use ExUnit.Case, async: true

  alias Sykli.RunHistory
  alias Sykli.RunHistory.{Run, TaskResult}
  alias Sykli.Verify

  @moduletag :tmp_dir

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp linux_node, do: %{node: :"worker@linux", labels: ["linux", "amd64"]}

  defp make_run(task_results) do
    %Run{
      id: "run-#{System.unique_integer([:positive])}",
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

  defp write_fixture(tmp_dir, tasks_json) do
    # Build fixture as: json = ~S|...|; IO.puts(json)
    # ~S sigil with | delimiter avoids all escaping issues
    fixture = "json = ~S|" <> tasks_json <> "|\nIO.puts(json)"
    File.write!(Path.join(tmp_dir, "sykli.exs"), fixture)
  end

  defp task_json(name, opts \\ []) do
    command = Keyword.get(opts, :command, "echo ok")
    verify = Keyword.get(opts, :verify, nil)

    base = ~s({"name":"#{name}","command":"#{command}")
    if verify, do: base <> ~s(,"verify":"#{verify}"}), else: base <> "}"
  end

  defp graph_json(task_jsons) do
    tasks = Enum.join(task_jsons, ",")
    ~s({"version":"1","tasks":[#{tasks}]})
  end

  defp setup_run_and_fixture(tmp_dir, run, task_jsons) do
    RunHistory.save(run, path: tmp_dir)
    write_fixture(tmp_dir, graph_json(task_jsons))
  end

  defp verify_opts(tmp_dir, overrides) do
    base = [
      path: tmp_dir,
      labels_fn: fn -> ["darwin", "arm64"] end,
      discover_fn: fn -> [linux_node()] end
    ]

    Keyword.merge(base, overrides)
  end

  # ── merge_results unit tests ────────────────────────────────────────────────

  describe "merge_results/3" do
    test "sets verified_on for passed tasks" do
      run = make_run([make_task_result("build"), make_task_result("test")])

      plan = %Verify.Plan{
        entries: [
          %Verify.Plan.Entry{
            task_name: "build",
            target_node: :"worker@linux",
            reason: :cross_platform
          }
        ],
        skipped: [{"test", :same_platform}],
        local_labels: ["darwin", "arm64"],
        remote_nodes: [linux_node()]
      }

      results = %{"build" => :ok}

      enriched = Verify.merge_results(run, plan, results)

      build = Enum.find(enriched.tasks, &(&1.name == "build"))
      test_task = Enum.find(enriched.tasks, &(&1.name == "test"))

      assert build.verified_on == "worker@linux"
      assert test_task.verified_on == nil
      assert enriched.verified == true
      assert enriched.verification["passed"] == 1
      assert enriched.verification["failed"] == 0
      assert enriched.verification["entries"] == 1
      assert enriched.verification["skipped"] == 1
    end

    test "counts failures correctly in verification map" do
      run = make_run([make_task_result("a"), make_task_result("b")])

      plan = %Verify.Plan{
        entries: [
          %Verify.Plan.Entry{task_name: "a", target_node: :"w@1", reason: :cross_platform},
          %Verify.Plan.Entry{task_name: "b", target_node: :"w@1", reason: :cross_platform}
        ],
        skipped: [],
        local_labels: ["darwin"],
        remote_nodes: []
      }

      results = %{"a" => :ok, "b" => {:error, "test failure"}}

      enriched = Verify.merge_results(run, plan, results)

      assert enriched.verification["passed"] == 1
      assert enriched.verification["failed"] == 1
      assert Enum.find(enriched.tasks, &(&1.name == "b")).verified_on == "w@1"
    end
  end

  # ── Full pipeline integration tests ─────────────────────────────────────────

  describe "verify/1 with injected fakes" do
    test "all tasks pass on remote", %{tmp_dir: tmp_dir} do
      run = make_run([make_task_result("build"), make_task_result("test")])
      setup_run_and_fixture(tmp_dir, run, [task_json("build"), task_json("test")])

      dispatch_fn = fn _task, _node, _opts -> :ok end

      assert {:ok, plan} = Verify.verify(verify_opts(tmp_dir, dispatch_fn: dispatch_fn))

      assert length(plan.entries) == 2
      entry_names = Enum.map(plan.entries, & &1.task_name) |> Enum.sort()
      assert entry_names == ["build", "test"]

      # Verify enriched run was saved
      {:ok, saved} = RunHistory.load_latest(path: tmp_dir)
      assert saved.verified == true
      assert saved.verification["passed"] == 2
      assert saved.verification["failed"] == 0

      build = Enum.find(saved.tasks, &(&1.name == "build"))
      assert build.verified_on == "worker@linux"
    end

    test "mixed pass/fail on remote", %{tmp_dir: tmp_dir} do
      run = make_run([make_task_result("lint"), make_task_result("test")])
      setup_run_and_fixture(tmp_dir, run, [task_json("lint"), task_json("test")])

      dispatch_fn = fn task, _node, _opts ->
        # dispatch_fn receives a %Graph.Task{} — key off the name
        if task.name == "lint", do: :ok, else: {:error, "assertion failed"}
      end

      assert {:ok, _plan} = Verify.verify(verify_opts(tmp_dir, dispatch_fn: dispatch_fn))

      {:ok, saved} = RunHistory.load_latest(path: tmp_dir)
      assert saved.verified == true
      assert saved.verification["passed"] == 1
      assert saved.verification["failed"] == 1
    end

    test "dispatch timeout handled gracefully", %{tmp_dir: tmp_dir} do
      run = make_run([make_task_result("build")])
      setup_run_and_fixture(tmp_dir, run, [task_json("build")])

      dispatch_fn = fn _task, _node, _opts -> {:error, :timeout} end

      assert {:ok, plan} = Verify.verify(verify_opts(tmp_dir, dispatch_fn: dispatch_fn))

      assert length(plan.entries) == 1

      {:ok, saved} = RunHistory.load_latest(path: tmp_dir)
      assert saved.verified == true
      assert saved.verification["failed"] == 1
      assert saved.verification["passed"] == 0
    end

    test "node disconnected mid-dispatch", %{tmp_dir: tmp_dir} do
      run = make_run([make_task_result("build")])
      setup_run_and_fixture(tmp_dir, run, [task_json("build")])

      dispatch_fn = fn _task, _node, _opts ->
        {:error, {:node_not_connected, :"worker@linux"}}
      end

      assert {:ok, _plan} = Verify.verify(verify_opts(tmp_dir, dispatch_fn: dispatch_fn))

      {:ok, saved} = RunHistory.load_latest(path: tmp_dir)
      assert saved.verified == true
      assert saved.verification["failed"] == 1

      build = Enum.find(saved.tasks, &(&1.name == "build"))
      assert build.verified_on == "worker@linux"
    end

    test "enriched run saved to disk with full verification data", %{tmp_dir: tmp_dir} do
      run = make_run([make_task_result("build"), make_task_result("test")])
      setup_run_and_fixture(tmp_dir, run, [task_json("build"), task_json("test")])

      dispatch_fn = fn _task, _node, _opts -> :ok end

      assert {:ok, _plan} = Verify.verify(verify_opts(tmp_dir, dispatch_fn: dispatch_fn))

      # Load the saved run and verify the full structure
      {:ok, saved} = RunHistory.load_latest(path: tmp_dir)

      assert saved.verified == true
      assert is_map(saved.verification)
      assert saved.verification["entries"] == 2
      assert saved.verification["skipped"] == 0
      assert saved.verification["passed"] == 2
      assert saved.verification["failed"] == 0

      # All dispatched tasks should have verified_on
      for task <- saved.tasks do
        assert task.verified_on != nil, "expected #{task.name} to have verified_on set"
      end
    end

    test "empty plan dispatches nothing", %{tmp_dir: tmp_dir} do
      run = make_run([make_task_result("build")])
      setup_run_and_fixture(tmp_dir, run, [task_json("build")])

      dispatch_called = :atomics.new(1, signed: false)

      dispatch_fn = fn _task, _node, _opts ->
        :atomics.add(dispatch_called, 1, 1)
        :ok
      end

      # Same platform → planner produces no entries
      opts =
        verify_opts(tmp_dir,
          discover_fn: fn -> [%{node: :"worker@mac2", labels: ["darwin", "arm64"]}] end,
          dispatch_fn: dispatch_fn
        )

      assert {:ok, plan} = Verify.verify(opts)

      assert plan.entries == []
      assert length(plan.skipped) == 1
      assert {"build", :same_platform} in plan.skipped

      # dispatch_fn should never have been called
      assert :atomics.get(dispatch_called, 1) == 0
    end
  end
end
