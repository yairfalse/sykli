defmodule Sykli.GraphViz do
  @moduledoc """
  Generates visual representations of the task graph.
  Supports Mermaid, DOT (Graphviz), and terminal status output.
  """

  @doc """
  Generates a compact status summary for terminal output.

  Takes tasks and a map of task_name => status (:passed, :failed, :skipped).

  Example output:
      test ✓ → build ✓ → deploy ✗ (skipped: lint)
  """
  def to_status_line(tasks, results) when is_list(tasks) and is_map(results) do
    # Build dependency levels
    levels = build_levels(tasks)

    # Format each level
    level_strs =
      levels
      |> Enum.map(fn level_tasks ->
        level_tasks
        |> Enum.map(fn task ->
          status = Map.get(results, task.name, :pending)
          format_task_status(task.name, status)
        end)
        |> Enum.join(", ")
      end)

    # Join levels with arrows
    main_line = Enum.join(level_strs, " → ")

    # Note any skipped tasks
    skipped =
      results
      |> Enum.filter(fn {_name, status} -> status == :skipped end)
      |> Enum.map(fn {name, _} -> name end)

    if skipped == [] do
      main_line
    else
      main_line <> " #{IO.ANSI.faint()}(skipped: #{Enum.join(skipped, ", ")})#{IO.ANSI.reset()}"
    end
  end

  defp format_task_status(name, :passed), do: "#{name} #{IO.ANSI.green()}✓#{IO.ANSI.reset()}"
  defp format_task_status(name, :failed), do: "#{name} #{IO.ANSI.red()}✗#{IO.ANSI.reset()}"
  defp format_task_status(name, :skipped), do: "#{IO.ANSI.faint()}#{name}#{IO.ANSI.reset()}"
  defp format_task_status(name, _), do: name

  defp build_levels(tasks) do
    task_map = Map.new(tasks, fn t -> {t.name, t} end)

    # Kahn's algorithm for level assignment
    in_degree =
      Map.new(tasks, fn t ->
        {t.name, length(Map.get(t, :depends_on, []) || [])}
      end)

    build_levels_loop(tasks, task_map, in_degree, [])
  end

  defp build_levels_loop(tasks, task_map, in_degree, levels) do
    # Find tasks with no remaining dependencies
    ready =
      in_degree
      |> Enum.filter(fn {_name, deg} -> deg == 0 end)
      |> Enum.map(fn {name, _} -> name end)
      |> Enum.sort()

    if ready == [] do
      Enum.reverse(levels)
    else
      # Get task structs for this level
      level_tasks =
        ready
        |> Enum.map(fn name -> Map.get(task_map, name) end)
        |> Enum.reject(&is_nil/1)

      # Remove these from in_degree and decrement dependents
      new_in_degree =
        in_degree
        |> Map.drop(ready)
        |> then(fn deg ->
          Enum.reduce(tasks, deg, fn task, acc ->
            deps = Map.get(task, :depends_on, []) || []

            if Enum.any?(deps, &(&1 in ready)) and Map.has_key?(acc, task.name) do
              Map.update!(acc, task.name, &(&1 - Enum.count(deps, fn d -> d in ready end)))
            else
              acc
            end
          end)
        end)

      build_levels_loop(tasks, task_map, new_in_degree, [level_tasks | levels])
    end
  end

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

  # Generate label - just the task name
  defp task_label(task) do
    task.name
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
