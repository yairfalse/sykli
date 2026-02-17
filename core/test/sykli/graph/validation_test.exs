defmodule Sykli.Graph.ValidationTest do
  use ExUnit.Case, async: true

  alias Sykli.Graph
  alias Sykli.Graph.Task

  describe "validate_dependencies/1" do
    test "returns :ok for valid graph" do
      graph = %{
        "lint" => %Task{name: "lint", command: "mix credo", depends_on: []},
        "test" => %Task{name: "test", command: "mix test", depends_on: ["lint"]},
        "build" => %Task{name: "build", command: "mix compile", depends_on: ["lint", "test"]}
      }

      assert :ok = Graph.validate_dependencies(graph)
    end

    test "returns :ok for graph with no dependencies" do
      graph = %{
        "a" => %Task{name: "a", command: "echo a", depends_on: []},
        "b" => %Task{name: "b", command: "echo b", depends_on: []}
      }

      assert :ok = Graph.validate_dependencies(graph)
    end

    test "returns :ok for graph with nil depends_on" do
      graph = %{
        "a" => %Task{name: "a", command: "echo a", depends_on: nil}
      }

      assert :ok = Graph.validate_dependencies(graph)
    end

    test "detects single missing dependency" do
      graph = %{
        "test" => %Task{name: "test", command: "mix test", depends_on: ["lint"]}
      }

      assert {:error, {:missing_dependencies, [{"test", ["lint"]}]}} =
               Graph.validate_dependencies(graph)
    end

    test "detects multiple missing dependencies on one task" do
      graph = %{
        "deploy" => %Task{name: "deploy", command: "deploy.sh", depends_on: ["build", "test"]}
      }

      {:error, {:missing_dependencies, [{_name, missing}]}} =
        Graph.validate_dependencies(graph)

      assert Enum.sort(missing) == ["build", "test"]
    end

    test "detects missing dependencies across multiple tasks" do
      graph = %{
        "a" => %Task{name: "a", command: "echo a", depends_on: ["missing1"]},
        "b" => %Task{name: "b", command: "echo b", depends_on: ["missing2"]}
      }

      {:error, {:missing_dependencies, pairs}} = Graph.validate_dependencies(graph)
      names = Enum.map(pairs, &elem(&1, 0)) |> Enum.sort()
      assert names == ["a", "b"]
    end
  end

  describe "topo_sort/1 catches missing dependencies" do
    test "returns error for missing dep before attempting sort" do
      graph = %{
        "test" => %Task{name: "test", command: "mix test", depends_on: ["lint"]}
      }

      assert {:error, {:missing_dependencies, _}} = Graph.topo_sort(graph)
    end

    test "valid graph still sorts correctly" do
      graph = %{
        "lint" => %Task{name: "lint", command: "mix credo", depends_on: []},
        "test" => %Task{name: "test", command: "mix test", depends_on: ["lint"]}
      }

      assert {:ok, [%Task{name: "lint"}, %Task{name: "test"}]} = Graph.topo_sort(graph)
    end
  end

  describe "cycle detection paths" do
    test "detects simple A→B→A cycle" do
      graph = %{
        "a" => %Task{name: "a", command: "echo a", depends_on: ["b"]},
        "b" => %Task{name: "b", command: "echo b", depends_on: ["a"]}
      }

      cycle = Graph.detect_cycle(graph)
      assert length(cycle) >= 2
      # Cycle should contain both a and b
      assert "a" in cycle
      assert "b" in cycle
    end

    test "detects A→B→C→A cycle" do
      graph = %{
        "a" => %Task{name: "a", command: "echo a", depends_on: ["b"]},
        "b" => %Task{name: "b", command: "echo b", depends_on: ["c"]},
        "c" => %Task{name: "c", command: "echo c", depends_on: ["a"]}
      }

      cycle = Graph.detect_cycle(graph)
      assert length(cycle) >= 3
      assert "a" in cycle
      assert "b" in cycle
      assert "c" in cycle
    end

    test "returns empty list for acyclic graph" do
      graph = %{
        "a" => %Task{name: "a", command: "echo a", depends_on: []},
        "b" => %Task{name: "b", command: "echo b", depends_on: ["a"]},
        "c" => %Task{name: "c", command: "echo c", depends_on: ["b"]}
      }

      assert [] = Graph.detect_cycle(graph)
    end
  end
end
