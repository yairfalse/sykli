defmodule Sykli.GraphViz do
  @moduledoc """
  Generates visual representations of the task graph.
  Supports Mermaid and DOT (Graphviz) output formats.
  """

  @doc """
  Generates a Mermaid diagram from a list of tasks.

  ## Example output:

      ```mermaid
      graph TD
          lint[lint]
          test[test]
          build[build]
          lint --> build
          test --> build
      ```
  """
  def to_mermaid(tasks) when is_list(tasks) do
    nodes = tasks |> Enum.map(&task_to_node/1) |> Enum.join("\n    ")
    edges = tasks |> Enum.flat_map(&task_to_edges/1) |> Enum.join("\n    ")

    """
    ```mermaid
    graph TD
        #{nodes}
        #{edges}
    ```
    """
    |> String.trim()
  end

  @doc """
  Generates a DOT (Graphviz) diagram from a list of tasks.

  ## Example output:

      digraph pipeline {
          rankdir=TD;
          lint -> build;
          test -> build;
      }
  """
  def to_dot(tasks) when is_list(tasks) do
    edges =
      tasks
      |> Enum.flat_map(&task_to_dot_edges/1)
      |> Enum.join("\n    ")

    nodes_without_edges =
      tasks
      |> Enum.filter(fn task ->
        deps = Map.get(task, :depends_on, []) || []
        deps == [] && !has_dependents?(task.name, tasks)
      end)
      |> Enum.map(fn task -> "#{sanitize_id(task.name)};" end)
      |> Enum.join("\n    ")

    """
    digraph pipeline {
        rankdir=TD;
        node [shape=box];
        #{nodes_without_edges}
        #{edges}
    }
    """
    |> String.trim()
  end

  # Check if any task depends on this one
  defp has_dependents?(name, tasks) do
    Enum.any?(tasks, fn task ->
      deps = Map.get(task, :depends_on, []) || []
      name in deps
    end)
  end

  # Convert task to mermaid node: `taskname[taskname]` or with icon
  defp task_to_node(task) do
    name = task.name
    id = sanitize_id(name)
    label = task_label(task)
    "#{id}[#{label}]"
  end

  # Generate label with optional icon based on task type
  defp task_label(task) do
    name = task.name

    cond do
      String.contains?(name, "test") -> "#{name} 🧪"
      String.contains?(name, "lint") -> "#{name} 🔍"
      String.contains?(name, "build") -> "#{name} 📦"
      String.contains?(name, "deploy") -> "#{name} 🚀"
      String.contains?(name, "fmt") or String.contains?(name, "format") -> "#{name} ✨"
      true -> name
    end
  end

  # Convert task dependencies to mermaid edges
  defp task_to_edges(task) do
    deps = Map.get(task, :depends_on, []) || []
    target = sanitize_id(task.name)

    Enum.map(deps, fn dep ->
      source = sanitize_id(dep)
      "#{source} --> #{target}"
    end)
  end

  # Convert task dependencies to DOT edges
  defp task_to_dot_edges(task) do
    deps = Map.get(task, :depends_on, []) || []
    target = sanitize_id(task.name)

    Enum.map(deps, fn dep ->
      source = sanitize_id(dep)
      "#{source} -> #{target};"
    end)
  end

  # Sanitize task name for use as graph node ID
  defp sanitize_id(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end
end
