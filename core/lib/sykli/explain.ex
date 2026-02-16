defmodule Sykli.Explain do
  @moduledoc """
  Pipeline analysis for AI assistants.

  Produces a structured description of the pipeline: tasks with their
  dependencies, execution levels, critical path, and estimated duration.

  This is the read-only, zero-cost way for an AI to understand a pipeline
  before deciding what to do.

  ## Usage

      {:ok, graph} = Sykli.Graph.parse(json)
      graph = Sykli.Graph.expand_matrix(graph)
      explanation = Sykli.Explain.pipeline(graph)

  """

  alias Sykli.Graph.Task

  @schema_version "1.0"

  @doc """
  Builds the full pipeline explanation map.

  Options:
    - `:sdk_file` - name of the SDK file (e.g. "sykli.go")
    - `:run_history` - a `Sykli.RunHistory.Run` struct for duration estimates
  """
  @spec pipeline(map(), keyword()) :: map()
  def pipeline(graph, opts \\ []) do
    sdk_file = Keyword.get(opts, :sdk_file)
    run_history = Keyword.get(opts, :run_history)

    levels = compute_levels(graph)
    blocks = compute_blocks(graph)
    duration_map = build_duration_map(run_history)
    critical_path = compute_critical_path(graph, duration_map)
    tasks_list = build_tasks_list(graph, blocks, levels, duration_map)

    max_parallelism =
      levels
      |> Enum.map(fn {_level, names} -> length(names) end)
      |> Enum.max(fn -> 0 end)

    estimated_duration_ms = estimate_total_duration(levels, duration_map)

    %{
      version: @schema_version,
      sdk_file: sdk_file,
      task_count: map_size(graph),
      tasks: tasks_list,
      execution_levels:
        levels
        |> Enum.sort_by(fn {level, _} -> level end)
        |> Enum.map(fn {level, names} -> %{level: level, tasks: Enum.sort(names)} end),
      critical_path: critical_path,
      estimated_duration_ms: estimated_duration_ms,
      parallelism: max_parallelism
    }
  end

  @doc """
  Groups tasks by execution level.

  Level 0 = tasks with no dependencies.
  Level N = tasks whose dependencies are all in levels < N.

  Returns a map of `%{level => [task_name]}`.
  """
  @spec compute_levels(map()) :: %{non_neg_integer() => [String.t()]}
  def compute_levels(graph) do
    # Iteratively assign levels: start with tasks that have no deps (level 0),
    # then find tasks whose deps are all assigned, repeat.
    do_compute_levels(graph, %{}, 0)
  end

  defp do_compute_levels(graph, assigned, current_level) do
    assigned_set = Map.keys(assigned) |> MapSet.new()

    # Find tasks not yet assigned whose deps are all assigned
    ready =
      graph
      |> Enum.filter(fn {name, task} ->
        not MapSet.member?(assigned_set, name) and
          Enum.all?(task.depends_on || [], &MapSet.member?(assigned_set, &1))
      end)
      |> Enum.map(fn {name, _} -> name end)

    if ready == [] do
      # All assigned (or cycle — but graph was already validated)
      assigned
      |> Enum.reduce(%{}, fn {_name, level}, acc ->
        Map.update(acc, level, [], & &1)
      end)
      |> then(fn level_map ->
        Enum.reduce(assigned, level_map, fn {name, level}, acc ->
          Map.update(acc, level, [name], &[name | &1])
        end)
      end)
    else
      new_assigned =
        Enum.reduce(ready, assigned, fn name, acc -> Map.put(acc, name, current_level) end)

      do_compute_levels(graph, new_assigned, current_level + 1)
    end
  end

  @doc """
  Computes reverse dependency map: for each task, which tasks does it block.

  If B depends on A, then A blocks B.
  """
  @spec compute_blocks(map()) :: %{String.t() => [String.t()]}
  def compute_blocks(graph) do
    Enum.reduce(graph, %{}, fn {name, task}, acc ->
      Enum.reduce(task.depends_on || [], acc, fn dep, inner_acc ->
        Map.update(inner_acc, dep, [name], &[name | &1])
      end)
    end)
  end

  @doc """
  Computes the critical path — the longest sequential chain weighted by duration.

  Uses dynamic programming on the DAG: for each task, the longest path ending
  at that task = max(longest path ending at each dep) + own duration.

  Returns task names in execution order.
  """
  @spec compute_critical_path(map(), %{String.t() => non_neg_integer()}) :: [String.t()]
  def compute_critical_path(graph, duration_map) do
    # Topologically process tasks, tracking longest path to each node
    levels = compute_levels(graph)

    sorted_names =
      levels
      |> Enum.sort_by(fn {level, _} -> level end)
      |> Enum.flat_map(fn {_level, names} -> names end)

    # dist[name] = {total_duration_to_here, predecessor}
    initial =
      Map.new(sorted_names, fn name -> {name, {duration_for(name, duration_map), nil}} end)

    dist =
      Enum.reduce(sorted_names, initial, fn name, acc ->
        task = Map.get(graph, name)
        own_duration = duration_for(name, duration_map)

        deps = task.depends_on || []

        if deps == [] do
          acc
        else
          # Find dep with maximum path length
          {best_dep, best_dist} =
            deps
            |> Enum.map(fn dep ->
              {dep_dist, _} = Map.get(acc, dep, {0, nil})
              {dep, dep_dist}
            end)
            |> Enum.max_by(fn {_, d} -> d end)

          new_dist = best_dist + own_duration

          {current_dist, _} = Map.get(acc, name, {0, nil})

          if new_dist > current_dist do
            Map.put(acc, name, {new_dist, best_dep})
          else
            acc
          end
        end
      end)

    # Find the task with the longest path
    case Map.to_list(dist) do
      [] ->
        []

      entries ->
        {end_task, _} = Enum.max_by(entries, fn {_, {d, _}} -> d end)
        reconstruct_path(dist, end_task, [])
    end
  end

  defp reconstruct_path(_dist, nil, path), do: path

  defp reconstruct_path(dist, name, path) do
    {_, pred} = Map.get(dist, name)
    reconstruct_path(dist, pred, [name | path])
  end

  defp duration_for(name, duration_map) do
    Map.get(duration_map, name, 1000)
  end

  defp build_duration_map(nil), do: %{}

  defp build_duration_map(%{tasks: tasks}) do
    Map.new(tasks, fn t -> {t.name, t.duration_ms || 1000} end)
  end

  defp build_duration_map(_), do: %{}

  defp estimate_total_duration(levels, duration_map) do
    # Per-level duration = max of task durations in that level
    # Total = sum of per-level durations (levels run sequentially)
    levels
    |> Enum.map(fn {_level, names} ->
      names
      |> Enum.map(&duration_for(&1, duration_map))
      |> Enum.max(fn -> 0 end)
    end)
    |> Enum.sum()
  end

  defp build_tasks_list(graph, blocks, levels, duration_map) do
    # Build name -> level lookup
    level_lookup =
      Enum.reduce(levels, %{}, fn {level, names}, acc ->
        Enum.reduce(names, acc, fn name, inner -> Map.put(inner, name, level) end)
      end)

    graph
    |> Enum.map(fn {_name, task} ->
      task_blocks = Map.get(blocks, task.name, []) |> Enum.sort()

      semantic = format_semantic(task)
      retry = format_retry(task)

      %{
        name: task.name,
        command: task.command,
        inputs: Task.inputs(task),
        depends_on: Task.depends_on(task),
        blocks: task_blocks,
        cacheable: Task.cacheable?(task),
        level: Map.get(level_lookup, task.name, 0),
        semantic: semantic,
        container: task.container,
        retry: retry,
        estimated_duration_ms: Map.get(duration_map, task.name)
      }
    end)
    |> Enum.sort_by(& &1.level)
  end

  defp format_semantic(task) do
    if Task.has_semantic?(task) do
      s = Task.semantic(task)

      %{
        covers: s.covers || [],
        intent: s.intent,
        criticality: if(s.criticality, do: Atom.to_string(s.criticality))
      }
    else
      nil
    end
  end

  defp format_retry(task) do
    if Task.retriable?(task) do
      task.retry
    else
      nil
    end
  end
end
