defmodule Sykli.GraphVizTest do
  use ExUnit.Case, async: true

  alias Sykli.GraphViz

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
