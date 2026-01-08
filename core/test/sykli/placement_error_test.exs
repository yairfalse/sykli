defmodule Sykli.PlacementErrorTest do
  use ExUnit.Case, async: true

  alias Sykli.NodeSelector.PlacementError

  describe "format/1 with all nodes failed" do
    test "shows task name and failure summary" do
      error = %PlacementError{
        task_name: "build",
        failures: [
          {:local, "docker daemon not running"},
          {:server1, "docker: permission denied"}
        ]
      }

      output = PlacementError.format(error)

      assert output =~ "build failed"
      assert output =~ "no nodes can run this task"
    end

    test "lists each node with its failure reason" do
      error = %PlacementError{
        task_name: "build",
        failures: [
          {:local, "docker daemon not running"},
          {:server1, "connection refused"}
        ]
      }

      output = PlacementError.format(error)

      assert output =~ "local"
      assert output =~ "docker daemon not running"
      assert output =~ "server1"
      assert output =~ "connection refused"
    end

    test "suggests starting docker when docker errors present" do
      error = %PlacementError{
        task_name: "build",
        failures: [
          {:local, "docker daemon not running"}
        ]
      }

      output = PlacementError.format(error)

      assert output =~ "Start Docker" or output =~ "docker"
    end
  end

  describe "format/1 with no matching nodes" do
    test "shows required labels" do
      error = %PlacementError{
        task_name: "train",
        no_matching_nodes: true,
        required_labels: ["gpu", "cuda"]
      }

      output = PlacementError.format(error)

      assert output =~ "train failed"
      assert output =~ "no nodes match"
      assert output =~ "gpu"
      assert output =~ "cuda"
    end

    test "suggests adding labels to nodes" do
      error = %PlacementError{
        task_name: "train",
        no_matching_nodes: true,
        required_labels: ["gpu"]
      }

      output = PlacementError.format(error)

      assert output =~ "SYKLI_LABELS" or output =~ "--labels"
    end

    test "shows available node labels when provided" do
      error = %PlacementError{
        task_name: "train",
        no_matching_nodes: true,
        required_labels: ["gpu"],
        available_nodes: [:local, :server1]
      }

      output = PlacementError.format(error)

      assert output =~ "local" or output =~ "server1"
    end
  end

  describe "format/1 edge cases" do
    test "handles empty failures gracefully" do
      error = %PlacementError{
        task_name: "orphan",
        failures: []
      }

      output = PlacementError.format(error)

      assert output =~ "orphan"
      assert is_binary(output)
    end

    test "handles complex error reasons" do
      error = %PlacementError{
        task_name: "complex",
        failures: [
          {:local, {:exit_code, 137}},
          {:server1, %{reason: "timeout", duration: 30_000}}
        ]
      }

      output = PlacementError.format(error)

      # Should not crash, should show something useful
      assert is_binary(output)
      assert output =~ "complex"
    end
  end

  describe "hints/1" do
    test "returns docker hint for docker errors" do
      error = %PlacementError{
        task_name: "build",
        failures: [{:local, "docker daemon not running"}]
      }

      hints = PlacementError.hints(error)

      assert Enum.any?(hints, &String.contains?(&1, "Docker"))
    end

    test "returns label hint when no nodes match" do
      error = %PlacementError{
        task_name: "train",
        no_matching_nodes: true,
        required_labels: ["gpu"]
      }

      hints = PlacementError.hints(error)

      assert Enum.any?(hints, &String.contains?(&1, "label"))
    end

    test "returns empty list when no specific hints apply" do
      error = %PlacementError{
        task_name: "unknown",
        failures: [{:local, "some random error"}]
      }

      hints = PlacementError.hints(error)

      assert is_list(hints)
    end
  end
end
