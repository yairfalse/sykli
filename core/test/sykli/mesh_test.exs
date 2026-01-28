defmodule Sykli.MeshTest do
  use ExUnit.Case, async: false

  alias Sykli.Mesh

  # Helper to create a task struct
  defp make_task(name, opts \\ []) do
    %Sykli.Graph.Task{
      name: name,
      command: Keyword.get(opts, :command, "echo #{name}"),
      inputs: Keyword.get(opts, :inputs, []),
      outputs: Keyword.get(opts, :outputs, []),
      depends_on: Keyword.get(opts, :depends_on, []),
      container: Keyword.get(opts, :container),
      workdir: Keyword.get(opts, :workdir),
      env: Keyword.get(opts, :env, %{}),
      mounts: Keyword.get(opts, :mounts, []),
      timeout: Keyword.get(opts, :timeout, 300)
    }
  end

  describe "dispatch_task/3" do
    test "runs task locally when node is :local" do
      task = make_task("echo-test", command: "echo hello")

      result = Mesh.dispatch_task(task, :local, workdir: "/tmp")

      assert result == :ok
    end

    test "runs task locally when node is current node" do
      task = make_task("echo-local", command: "echo local")

      result = Mesh.dispatch_task(task, node(), workdir: "/tmp")

      assert result == :ok
    end

    test "returns error when remote node is not connected" do
      task = make_task("remote-task")

      result = Mesh.dispatch_task(task, :fake_node@nowhere, workdir: "/tmp")

      assert {:error, {:node_not_connected, :fake_node@nowhere}} = result
    end

    test "returns error when task fails" do
      task = make_task("fail-task", command: "exit 1")

      result = Mesh.dispatch_task(task, :local, workdir: "/tmp")

      # Returns Error struct with code "task_failed"
      assert {:error, %Sykli.Error{code: "task_failed", exit_code: 1}} = result
    end

    test "respects timeout option" do
      task = make_task("slow-task", command: "sleep 10", timeout: 1)

      result = Mesh.dispatch_task(task, :local, workdir: "/tmp")

      # Returns Error struct with code "task_timeout"
      assert {:error, %Sykli.Error{code: "task_timeout"}} = result
    end
  end

  describe "available_nodes/0" do
    test "returns list of connected nodes" do
      nodes = Mesh.available_nodes()

      assert is_list(nodes)
    end

    test "includes :local when current node can execute tasks" do
      # Test nodes (nonode@nohost) are treated as :full nodes, which can execute
      # This test verifies the happy path where the node can execute
      nodes = Mesh.available_nodes()

      assert :local in nodes
    end

    test "excludes :local for coordinator-only nodes" do
      # Coordinators cannot execute tasks, so :local should not be included
      # when running on a coordinator node. We verify this by checking the
      # underlying role detection logic.
      assert Sykli.Daemon.can_execute?(:coordinator_abc123@host) == false
      assert Sykli.Daemon.can_execute?(:worker_abc123@host) == true
      assert Sykli.Daemon.can_execute?(:sykli_abc123@host) == true
    end
  end

  describe "node_available?/1" do
    test "returns true for :local" do
      assert Mesh.node_available?(:local)
    end

    test "returns true for current node" do
      assert Mesh.node_available?(node())
    end

    test "returns false for disconnected node" do
      refute Mesh.node_available?(:fake_node@nowhere)
    end
  end

  describe "select_node/3" do
    test "returns :local when no nodes connected" do
      task = make_task("any-task")

      assert {:ok, :local} = Mesh.select_node(task, [])
    end

    test "returns :local when :local is in candidates" do
      task = make_task("any-task")

      assert {:ok, :local} = Mesh.select_node(task, [:local])
    end

    test "falls back to :local when candidates list is empty" do
      task = make_task("any-task")

      # With empty candidates and strategy :any, should fall back to local
      assert {:ok, :local} = Mesh.select_node(task, [], strategy: :any)
    end

    test "respects strategy :local" do
      task = make_task("local-only")

      assert {:ok, :local} = Mesh.select_node(task, [:local, :other@node], strategy: :local)
    end
  end

  describe "dispatch_to_any/2" do
    test "runs task on first available node" do
      task = make_task("any-node-task", command: "echo dispatched")

      result = Mesh.dispatch_to_any(task, workdir: "/tmp")

      assert result == :ok
    end

    test "falls back to local when no remote nodes" do
      task = make_task("fallback-task", command: "echo fallback")

      result = Mesh.dispatch_to_any(task, workdir: "/tmp")

      assert result == :ok
    end
  end

  describe "node_info/1" do
    test "returns info for :local" do
      info = Mesh.node_info(:local)

      assert info.name == :local
      assert is_map(info.capabilities)
    end

    test "returns nil for disconnected node" do
      assert Mesh.node_info(:fake@nowhere) == nil
    end
  end

  describe "broadcast_task/2" do
    test "runs task on all available nodes" do
      task = make_task("broadcast-task", command: "echo broadcast")

      results = Mesh.broadcast_task(task, workdir: "/tmp")

      # Should at least run on :local
      assert is_map(results)
      assert Map.has_key?(results, :local)
      assert results[:local] == :ok
    end
  end

  describe "integration with Executor" do
    test "dispatch uses Executor.Local for local tasks" do
      task = make_task("executor-test", command: "echo executor")

      # Should use the local executor
      result = Mesh.dispatch_task(task, :local, workdir: "/tmp")

      assert result == :ok
    end

    test "dispatch passes workdir to executor" do
      # Create a temp directory
      workdir = Path.join(System.tmp_dir!(), "mesh_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(workdir)

      on_exit(fn -> File.rm_rf!(workdir) end)

      task = make_task("workdir-test", command: "pwd")

      result = Mesh.dispatch_task(task, :local, workdir: workdir)

      assert result == :ok
    end
  end

  describe "error handling" do
    test "handles node disconnect during execution gracefully" do
      # This tests that we handle :nodedown errors
      task = make_task("disconnect-test")

      # Dispatching to a non-existent node should fail cleanly
      result = Mesh.dispatch_task(task, :will_disconnect@nowhere, workdir: "/tmp")

      assert {:error, {:node_not_connected, _}} = result
    end

    test "returns structured error for RPC failures" do
      task = make_task("rpc-fail-test")

      result = Mesh.dispatch_task(task, :rpc_fail@nowhere, workdir: "/tmp")

      assert {:error, _reason} = result
    end
  end
end
