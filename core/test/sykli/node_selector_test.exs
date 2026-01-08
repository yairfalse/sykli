defmodule Sykli.NodeSelectorTest do
  use ExUnit.Case, async: true

  alias Sykli.NodeSelector
  alias Sykli.NodeSelector.PlacementError

  # Mock node capabilities for testing
  defp mock_capabilities do
    %{
      local: %{labels: ["darwin", "arm64", "docker"]},
      server1: %{labels: ["linux", "amd64", "docker", "gpu"]},
      server2: %{labels: ["linux", "amd64", "docker"]},
      no_docker: %{labels: ["linux", "amd64"]}
    }
  end

  # Simple task struct for testing
  defp task(opts \\ []) do
    %{
      name: Keyword.get(opts, :name, "test-task"),
      requires: Keyword.get(opts, :requires, []),
      command: Keyword.get(opts, :command, "echo hello")
    }
  end

  describe "filter_by_labels/3" do
    test "returns all nodes when task has no requirements" do
      nodes = [:local, :server1, :server2]
      caps = mock_capabilities()

      result = NodeSelector.filter_by_labels(task(), nodes, caps)

      assert result == [:local, :server1, :server2]
    end

    test "filters nodes by required label" do
      nodes = [:local, :server1, :server2, :no_docker]
      caps = mock_capabilities()
      t = task(requires: ["gpu"])

      result = NodeSelector.filter_by_labels(t, nodes, caps)

      assert result == [:server1]
    end

    test "filters by multiple required labels" do
      nodes = [:local, :server1, :server2]
      caps = mock_capabilities()
      t = task(requires: ["docker", "linux"])

      result = NodeSelector.filter_by_labels(t, nodes, caps)

      # server1 and server2 have both docker and linux
      assert :server1 in result
      assert :server2 in result
      refute :local in result  # darwin, not linux
    end

    test "returns empty when no nodes match" do
      nodes = [:local, :server1, :server2]
      caps = mock_capabilities()
      t = task(requires: ["kubernetes"])  # nobody has this

      result = NodeSelector.filter_by_labels(t, nodes, caps)

      assert result == []
    end
  end

  describe "try_nodes/4" do
    # Mock runner that succeeds on specific nodes
    defp success_runner(success_nodes) do
      fn node, _task, _opts ->
        if node in success_nodes do
          :ok
        else
          {:error, "node #{node} failed"}
        end
      end
    end

    test "returns {:ok, node} on first success" do
      runner = success_runner([:server1, :server2])

      result = NodeSelector.try_nodes(
        task(),
        [:local, :server1, :server2],
        [],
        runner
      )

      # local fails, server1 succeeds
      assert {:ok, :server1} = result
    end

    test "tries nodes in order" do
      tried = Agent.start_link(fn -> [] end) |> elem(1)

      runner = fn node, _task, _opts ->
        Agent.update(tried, &[node | &1])
        {:error, "always fail"}
      end

      NodeSelector.try_nodes(task(), [:local, :server1, :server2], [], runner)

      order = Agent.get(tried, & &1) |> Enum.reverse()
      assert order == [:local, :server1, :server2]
    end

    test "returns {:ok, node} immediately when first node succeeds" do
      tried = Agent.start_link(fn -> [] end) |> elem(1)

      runner = fn node, _task, _opts ->
        Agent.update(tried, &[node | &1])
        :ok  # always succeed
      end

      {:ok, :local} = NodeSelector.try_nodes(
        task(),
        [:local, :server1, :server2],
        [],
        runner
      )

      # Should only try first node
      assert Agent.get(tried, & &1) == [:local]
    end

    test "collects failures into PlacementError" do
      runner = fn node, _task, _opts ->
        {:error, "#{node} exploded"}
      end

      result = NodeSelector.try_nodes(
        task(name: "build"),
        [:local, :server1],
        [],
        runner
      )

      assert {:error, %PlacementError{} = error} = result
      assert error.task_name == "build"
      assert length(error.failures) == 2
      assert {:local, "local exploded"} in error.failures
      assert {:server1, "server1 exploded"} in error.failures
    end

    test "returns PlacementError when no nodes provided" do
      runner = fn _, _, _ -> :ok end

      result = NodeSelector.try_nodes(task(name: "orphan"), [], [], runner)

      assert {:error, %PlacementError{} = error} = result
      assert error.task_name == "orphan"
      assert error.failures == []
    end
  end

  describe "select_and_try/5" do
    test "filters by labels then tries nodes" do
      caps = mock_capabilities()

      runner = fn node, _task, _opts ->
        if node == :server1, do: :ok, else: {:error, "nope"}
      end

      result = NodeSelector.select_and_try(
        task(requires: ["gpu"]),
        [:local, :server1, :server2],
        caps,
        [],
        runner
      )

      # Only server1 has gpu, and it succeeds
      assert {:ok, :server1} = result
    end

    test "returns error when no nodes match requirements" do
      caps = mock_capabilities()
      runner = fn _, _, _ -> :ok end

      result = NodeSelector.select_and_try(
        task(name: "k8s-task", requires: ["kubernetes"]),
        [:local, :server1],
        caps,
        [],
        runner
      )

      assert {:error, %PlacementError{} = error} = result
      assert error.task_name == "k8s-task"
      assert error.no_matching_nodes == true
      assert error.required_labels == ["kubernetes"]
    end
  end
end
