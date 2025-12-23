defmodule Sykli.GraphVizTest do
  use ExUnit.Case, async: true

  alias Sykli.GraphViz

  describe "to_mermaid/1" do
    test "generates mermaid for simple pipeline" do
      tasks = [
        %{name: "lint", depends_on: []},
        %{name: "test", depends_on: []},
        %{name: "build", depends_on: ["lint", "test"]}
      ]

      result = GraphViz.to_mermaid(tasks)

      assert result =~ "graph TD"
      assert result =~ "lint"
      assert result =~ "test"
      assert result =~ "build"
      assert result =~ "lint --> build"
      assert result =~ "test --> build"
    end

    test "adds icons based on task name" do
      tasks = [
        %{name: "test", depends_on: []},
        %{name: "lint", depends_on: []},
        %{name: "build", depends_on: []},
        %{name: "deploy", depends_on: []}
      ]

      result = GraphViz.to_mermaid(tasks)

      assert result =~ "test 🧪"
      assert result =~ "lint 🔍"
      assert result =~ "build 📦"
      assert result =~ "deploy 🚀"
    end

    test "handles tasks with no dependencies" do
      tasks = [
        %{name: "standalone", depends_on: []}
      ]

      result = GraphViz.to_mermaid(tasks)

      assert result =~ "standalone[standalone]"
      refute result =~ "-->"
    end

    test "handles nil depends_on" do
      tasks = [
        %{name: "task1", depends_on: nil},
        %{name: "task2", depends_on: ["task1"]}
      ]

      result = GraphViz.to_mermaid(tasks)

      assert result =~ "task1 --> task2"
    end
  end

  describe "to_dot/1" do
    test "generates DOT format" do
      tasks = [
        %{name: "lint", depends_on: []},
        %{name: "build", depends_on: ["lint"]}
      ]

      result = GraphViz.to_dot(tasks)

      assert result =~ "digraph pipeline"
      assert result =~ "rankdir=TD"
      assert result =~ "lint -> build;"
    end

    test "includes orphan nodes" do
      tasks = [
        %{name: "standalone", depends_on: []}
      ]

      result = GraphViz.to_dot(tasks)

      assert result =~ "standalone;"
    end

    test "sanitizes special characters in names" do
      tasks = [
        %{name: "my-task", depends_on: []},
        %{name: "other.task", depends_on: ["my-task"]}
      ]

      result = GraphViz.to_dot(tasks)

      assert result =~ "my_task -> other_task;"
    end
  end
end
