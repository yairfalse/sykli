defmodule Sykli.GraphVizTest do
  use ExUnit.Case, async: true

  alias Sykli.GraphViz

  describe "to_status_line/2" do
    test "shows single task with status" do
      tasks = [%{name: "test", depends_on: []}]
      results = %{"test" => :passed}

      result = GraphViz.to_status_line(tasks, results)

      assert result =~ "test"
      assert result =~ "✓"
    end

    test "shows linear pipeline with arrows" do
      tasks = [
        %{name: "test", depends_on: []},
        %{name: "build", depends_on: ["test"]}
      ]
      results = %{"test" => :passed, "build" => :passed}

      result = GraphViz.to_status_line(tasks, results)

      assert result =~ "test"
      assert result =~ "→"
      assert result =~ "build"
    end

    test "shows failed task" do
      tasks = [%{name: "test", depends_on: []}]
      results = %{"test" => :failed}

      result = GraphViz.to_status_line(tasks, results)

      assert result =~ "test"
      assert result =~ "✗"
    end

    test "shows parallel tasks at same level" do
      tasks = [
        %{name: "lint", depends_on: []},
        %{name: "test", depends_on: []},
        %{name: "build", depends_on: ["lint", "test"]}
      ]
      results = %{"lint" => :passed, "test" => :passed, "build" => :passed}

      result = GraphViz.to_status_line(tasks, results)

      # lint and test should be at same level (comma-separated)
      assert result =~ "lint"
      assert result =~ "test"
      assert result =~ "→"
      assert result =~ "build"
    end

    test "shows skipped tasks" do
      tasks = [
        %{name: "test", depends_on: []},
        %{name: "deploy", depends_on: ["test"]}
      ]
      results = %{"test" => :failed, "deploy" => :skipped}

      result = GraphViz.to_status_line(tasks, results)

      assert result =~ "skipped"
      assert result =~ "deploy"
    end
  end

  describe "to_mermaid/1" do
    test "renders empty graph" do
      result = GraphViz.to_mermaid([])

      assert result =~ "graph TD"
    end

    test "renders single task" do
      tasks = [%{name: "test", depends_on: []}]

      result = GraphViz.to_mermaid(tasks)

      assert result =~ "graph TD"
      assert result =~ "test"
    end

    test "renders task with dependency" do
      tasks = [
        %{name: "test", depends_on: []},
        %{name: "build", depends_on: ["test"]}
      ]

      result = GraphViz.to_mermaid(tasks)

      assert result =~ "graph TD"
      assert result =~ "test --> build"
    end

    test "renders multiple dependencies" do
      tasks = [
        %{name: "lint", depends_on: []},
        %{name: "test", depends_on: []},
        %{name: "build", depends_on: ["lint", "test"]}
      ]

      result = GraphViz.to_mermaid(tasks)

      assert result =~ "lint --> build"
      assert result =~ "test --> build"
    end

    test "uses plain task names without decoration" do
      tasks = [
        %{name: "test", depends_on: []},
        %{name: "lint", depends_on: []},
        %{name: "build", depends_on: []}
      ]

      result = GraphViz.to_mermaid(tasks)

      assert result =~ "test[test]"
      assert result =~ "lint[lint]"
      assert result =~ "build[build]"
    end

    test "sanitizes special characters in task names" do
      tasks = [%{name: "my-task", depends_on: []}]

      result = GraphViz.to_mermaid(tasks)

      # Hyphens get replaced with underscores
      assert result =~ "my_task"
    end

    test "handles nil depends_on" do
      tasks = [
        %{name: "test", depends_on: nil},
        %{name: "build", depends_on: ["test"]}
      ]

      result = GraphViz.to_mermaid(tasks)

      assert result =~ "test --> build"
    end
  end

  describe "to_dot/1" do
    test "renders empty graph" do
      result = GraphViz.to_dot([])

      assert result =~ "digraph"
      assert result =~ "}"
    end

    test "renders single task" do
      tasks = [%{name: "test", depends_on: []}]

      result = GraphViz.to_dot(tasks)

      assert result =~ "digraph"
      assert result =~ "test"
    end

    test "renders task with dependency" do
      tasks = [
        %{name: "test", depends_on: []},
        %{name: "build", depends_on: ["test"]}
      ]

      result = GraphViz.to_dot(tasks)

      assert result =~ "test -> build"
    end

    test "renders multiple dependencies" do
      tasks = [
        %{name: "lint", depends_on: []},
        %{name: "test", depends_on: []},
        %{name: "build", depends_on: ["lint", "test"]}
      ]

      result = GraphViz.to_dot(tasks)

      assert result =~ "lint -> build"
      assert result =~ "test -> build"
    end

    test "includes standalone nodes without edges" do
      tasks = [%{name: "solo", depends_on: []}]

      result = GraphViz.to_dot(tasks)

      assert result =~ "solo;"
    end
  end
end
