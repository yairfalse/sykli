defmodule Sykli.ExplainTest do
  use ExUnit.Case, async: true

  alias Sykli.Explain
  alias Sykli.Graph

  describe "pipeline/2" do
    test "returns schema version and task count" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "test", "command" => "mix test"}
        ])

      result = Explain.pipeline(graph)

      assert result.version == "1.0"
      assert result.task_count == 2
      assert length(result.tasks) == 2
    end

    test "includes sdk_file when provided" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "test", "command" => "mix test"}
        ])

      result = Explain.pipeline(graph, sdk_file: "sykli.go")
      assert result.sdk_file == "sykli.go"
    end

    test "task entries include all expected fields" do
      {:ok, graph} =
        parse_graph([
          %{
            "name" => "test",
            "command" => "mix test",
            "inputs" => ["**/*.ex"],
            "container" => "elixir:1.16",
            "retry" => 2,
            "semantic" => %{
              "covers" => ["lib/auth/*"],
              "intent" => "unit tests",
              "criticality" => "high"
            }
          }
        ])

      result = Explain.pipeline(graph)
      task = Enum.find(result.tasks, &(&1.name == "test"))

      assert task.command == "mix test"
      assert task.inputs == ["**/*.ex"]
      assert task.depends_on == []
      assert task.blocks == []
      assert task.cacheable == true
      assert task.level == 0
      assert task.container == "elixir:1.16"
      assert task.retry == 2
      assert task.semantic.covers == ["lib/auth/*"]
      assert task.semantic.intent == "unit tests"
      assert task.semantic.criticality == "high"
    end

    test "tasks without semantic have nil semantic" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"}
        ])

      result = Explain.pipeline(graph)
      task = Enum.find(result.tasks, &(&1.name == "lint"))

      assert task.semantic == nil
    end

    test "tasks without inputs are not cacheable" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"}
        ])

      result = Explain.pipeline(graph)
      task = Enum.find(result.tasks, &(&1.name == "lint"))

      assert task.cacheable == false
    end

    test "tasks without retry have nil retry" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"}
        ])

      result = Explain.pipeline(graph)
      task = Enum.find(result.tasks, &(&1.name == "lint"))

      assert task.retry == nil
    end
  end

  describe "compute_levels/1" do
    test "single task gets level 0" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "test", "command" => "mix test"}
        ])

      levels = Explain.compute_levels(graph)

      assert levels[0] == ["test"]
    end

    test "independent tasks share level 0" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "format", "command" => "mix format --check"}
        ])

      levels = Explain.compute_levels(graph)

      assert Enum.sort(levels[0]) == ["format", "lint"]
    end

    test "dependent tasks get higher levels" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "test", "command" => "mix test", "depends_on" => ["lint"]},
          %{"name" => "build", "command" => "mix compile", "depends_on" => ["test"]}
        ])

      levels = Explain.compute_levels(graph)

      assert levels[0] == ["lint"]
      assert levels[1] == ["test"]
      assert levels[2] == ["build"]
    end

    test "diamond dependency graph levels correctly" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "setup", "command" => "npm install"},
          %{"name" => "lint", "command" => "eslint .", "depends_on" => ["setup"]},
          %{"name" => "test", "command" => "jest", "depends_on" => ["setup"]},
          %{"name" => "build", "command" => "webpack", "depends_on" => ["lint", "test"]}
        ])

      levels = Explain.compute_levels(graph)

      assert levels[0] == ["setup"]
      assert Enum.sort(levels[1]) == ["lint", "test"]
      assert levels[2] == ["build"]
    end
  end

  describe "execution_levels in pipeline output" do
    test "levels are sorted and tasks within levels are sorted" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "c_task", "command" => "echo c"},
          %{"name" => "a_task", "command" => "echo a"},
          %{"name" => "b_task", "command" => "echo b", "depends_on" => ["c_task", "a_task"]}
        ])

      result = Explain.pipeline(graph)

      assert [level0, level1] = result.execution_levels
      assert level0.level == 0
      assert level0.tasks == ["a_task", "c_task"]
      assert level1.level == 1
      assert level1.tasks == ["b_task"]
    end
  end

  describe "compute_blocks/1" do
    test "returns empty map for independent tasks" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "a", "command" => "echo a"},
          %{"name" => "b", "command" => "echo b"}
        ])

      blocks = Explain.compute_blocks(graph)
      assert blocks == %{}
    end

    test "maps blocking relationships correctly" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "test", "command" => "mix test", "depends_on" => ["lint"]},
          %{"name" => "build", "command" => "mix compile", "depends_on" => ["lint"]}
        ])

      blocks = Explain.compute_blocks(graph)

      assert Enum.sort(blocks["lint"]) == ["build", "test"]
      refute Map.has_key?(blocks, "test")
      refute Map.has_key?(blocks, "build")
    end
  end

  describe "blocks in pipeline output" do
    test "task entries include sorted blocks" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "test", "command" => "mix test", "depends_on" => ["lint"]},
          %{"name" => "build", "command" => "mix compile", "depends_on" => ["lint"]}
        ])

      result = Explain.pipeline(graph)
      lint_task = Enum.find(result.tasks, &(&1.name == "lint"))

      assert lint_task.blocks == ["build", "test"]
    end
  end

  describe "compute_critical_path/2" do
    test "single task is the critical path" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "test", "command" => "mix test"}
        ])

      path = Explain.compute_critical_path(graph, %{})
      assert path == ["test"]
    end

    test "linear chain is the full critical path" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "test", "command" => "mix test", "depends_on" => ["lint"]},
          %{"name" => "build", "command" => "mix compile", "depends_on" => ["test"]}
        ])

      path = Explain.compute_critical_path(graph, %{})
      assert path == ["lint", "test", "build"]
    end

    test "picks longer branch when weighted equally" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "setup", "command" => "npm install"},
          %{"name" => "lint", "command" => "eslint .", "depends_on" => ["setup"]},
          %{"name" => "test", "command" => "jest", "depends_on" => ["setup"]},
          %{"name" => "build", "command" => "webpack", "depends_on" => ["lint", "test"]}
        ])

      # Both branches have same weight (default 1000ms each)
      # Either [setup, lint, build] or [setup, test, build] is valid
      path = Explain.compute_critical_path(graph, %{})

      assert List.first(path) == "setup"
      assert List.last(path) == "build"
      assert length(path) == 3
    end

    test "uses duration map for weighting" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "setup", "command" => "npm install"},
          %{"name" => "fast", "command" => "echo fast", "depends_on" => ["setup"]},
          %{"name" => "slow", "command" => "sleep 10", "depends_on" => ["setup"]},
          %{"name" => "build", "command" => "webpack", "depends_on" => ["fast", "slow"]}
        ])

      duration_map = %{"setup" => 1000, "fast" => 500, "slow" => 10000, "build" => 2000}
      path = Explain.compute_critical_path(graph, duration_map)

      assert path == ["setup", "slow", "build"]
    end

    test "empty graph returns empty path" do
      path = Explain.compute_critical_path(%{}, %{})
      assert path == []
    end
  end

  describe "parallelism" do
    test "reports max parallel tasks across levels" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "setup", "command" => "npm install"},
          %{"name" => "lint", "command" => "eslint .", "depends_on" => ["setup"]},
          %{"name" => "test", "command" => "jest", "depends_on" => ["setup"]},
          %{"name" => "typecheck", "command" => "tsc", "depends_on" => ["setup"]},
          %{
            "name" => "build",
            "command" => "webpack",
            "depends_on" => ["lint", "test", "typecheck"]
          }
        ])

      result = Explain.pipeline(graph)
      assert result.parallelism == 3
    end
  end

  describe "estimated_duration_ms" do
    test "estimates based on max-per-level with default durations" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "test", "command" => "mix test", "depends_on" => ["lint"]}
        ])

      result = Explain.pipeline(graph)

      # Two levels, each with 1 task at default 1000ms = 2000ms
      assert result.estimated_duration_ms == 2000
    end

    test "uses run history durations when available" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "test", "command" => "mix test", "depends_on" => ["lint"]}
        ])

      run_history = %{
        tasks: [
          %{name: "lint", duration_ms: 500},
          %{name: "test", duration_ms: 3000}
        ]
      }

      result = Explain.pipeline(graph, run_history: run_history)

      # Level 0: lint (500ms), Level 1: test (3000ms) → 3500ms
      assert result.estimated_duration_ms == 3500
    end
  end

  describe "matrix expansion" do
    test "works with expanded matrix tasks" do
      {:ok, graph} =
        parse_graph([
          %{
            "name" => "test",
            "command" => "mix test",
            "matrix" => %{"version" => ["1.15", "1.16"]}
          }
        ])

      expanded = Graph.expand_matrix(graph)
      result = Explain.pipeline(expanded)

      assert result.task_count == 2
      names = Enum.map(result.tasks, & &1.name) |> Enum.sort()
      assert names == ["test-1.15", "test-1.16"]
    end
  end

  # Helpers

  defp parse_graph(tasks) do
    json = Jason.encode!(%{"tasks" => tasks})
    Graph.parse(json)
  end
end
