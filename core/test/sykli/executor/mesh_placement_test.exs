defmodule Sykli.Executor.MeshPlacementTest do
  @moduledoc """
  Tests for task placement with requires labels in mesh execution.

  These tests verify that:
  1. Tasks with requires labels are only dispatched to matching nodes
  2. PlacementError is returned when no nodes match
  3. Rich error messages help users fix placement issues
  """
  use ExUnit.Case, async: true

  alias Sykli.Executor.Mesh
  alias Sykli.NodeSelector.PlacementError

  # Create a mock task with requires labels
  defp task(opts \\ []) do
    %Sykli.Graph.Task{
      name: Keyword.get(opts, :name, "test"),
      command: Keyword.get(opts, :command, "echo hello"),
      requires: Keyword.get(opts, :requires, []),
      inputs: [],
      outputs: %{},
      depends_on: [],
      mounts: [],
      env: %{},
      secrets: [],
      services: [],
      task_inputs: []
    }
  end

  describe "run_task/3 with requires labels" do
    test "task without requires runs on any available node" do
      # This test verifies the base case - no labels means run anywhere
      # In isolation (no mesh), this should run locally
      t = task(name: "no-labels", command: "echo success")

      {:ok, state} = Mesh.setup(workdir: System.tmp_dir!())
      result = Mesh.run_task(t, state, [])
      Mesh.teardown(state)

      # Should succeed (runs locally when no remote nodes)
      assert {:ok, _output} = result
    end

    test "task with unsatisfiable requires returns PlacementError" do
      # Task requires a label that no node has
      t = task(name: "impossible", command: "echo", requires: ["quantum-computer"])

      {:ok, state} = Mesh.setup(workdir: System.tmp_dir!())
      result = Mesh.run_task(t, state, [])
      Mesh.teardown(state)

      # Should fail with placement error
      assert {:error, %PlacementError{} = error} = result
      assert error.task_name == "impossible"
      assert error.no_matching_nodes == true
      assert "quantum-computer" in error.required_labels
    end

    test "task with matching requires runs successfully" do
      # Task requires docker - local node should have it if docker is installed
      t = task(name: "docker-task", command: "echo docker", requires: ["docker"])

      {:ok, state} = Mesh.setup(workdir: System.tmp_dir!())

      # Check if local node has docker label
      caps = Sykli.Mesh.local_capabilities()
      has_docker = "docker" in (caps.labels || []) or caps[:docker] == true

      result = Mesh.run_task(t, state, [])
      Mesh.teardown(state)

      if has_docker do
        assert {:ok, _output} = result
      else
        # No docker, should get placement error
        assert {:error, %PlacementError{}} = result
      end
    end
  end
end
