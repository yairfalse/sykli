defmodule Sykli.Plan do
  @moduledoc """
  Dry-run execution planning for AI assistants.

  Given the current git diff and task graph, produces a structured plan
  showing what tasks would run, in what order, with cache predictions
  and reasoning — all without executing anything.

  Composes existing modules:
  - `Delta` for change detection
  - `Cache` for cache predictions
  - `Explain` for execution levels and critical path

  ## Usage

      {:ok, graph} = Sykli.Graph.parse(json)
      graph = Sykli.Graph.expand_matrix(graph)
      {:ok, plan} = Sykli.Plan.generate(graph, from: "origin/main", path: ".")
  """

  alias Sykli.{Delta, Cache, Explain}
  alias Sykli.Graph.Task

  @schema_version "1.0"

  @doc """
  Generates a dry-run execution plan.

  Options:
    - `:from` - git ref to compare against (default: auto-detected)
    - `:path` - project path (default: ".")
    - `:run_history` - a `Sykli.RunHistory.Run` struct for duration estimates
  """
  @spec generate(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate(graph, opts \\ []) do
    from = Keyword.get(opts, :from) || detect_base_branch(Keyword.get(opts, :path, "."))
    path = Keyword.get(opts, :path, ".")
    run_history = Keyword.get(opts, :run_history)

    tasks_list = Map.values(graph)

    case Delta.affected_tasks_detailed(tasks_list, from: from, path: path) do
      {:ok, affected} ->
        plan = build_plan(graph, affected, from, path, run_history)
        {:ok, plan}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Predicts cache status for each task in the graph.

  Returns a map of `%{task_name => %{cached: boolean, reason: atom | nil}}`.
  """
  @spec predict_cache(map(), String.t()) :: %{
          String.t() => %{cached: boolean(), reason: atom() | nil}
        }
  def predict_cache(graph, workdir) do
    Map.new(graph, fn {name, task} ->
      if Task.cacheable?(task) do
        case Cache.check_detailed(task, workdir) do
          {:hit, _key} ->
            {name, %{cached: true, reason: nil}}

          {:miss, _key, reason} ->
            {name, %{cached: false, reason: reason}}
        end
      else
        {name, %{cached: false, reason: :not_cacheable}}
      end
    end)
  end

  @doc """
  Detects the base branch to compare against.

  Tries origin/main, then origin/master, falls back to HEAD.
  """
  @spec detect_base_branch(String.t()) :: String.t()
  def detect_base_branch(path \\ ".") do
    cond do
      ref_exists?("origin/main", path) -> "origin/main"
      ref_exists?("origin/master", path) -> "origin/master"
      true -> "HEAD"
    end
  end

  # --- Private ---

  defp ref_exists?(ref, path) do
    case Sykli.Git.run(["rev-parse", "--verify", ref], cd: path) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp build_plan(graph, affected, from, path, run_history) do
    affected_names = MapSet.new(Enum.map(affected, & &1.name))

    # Build affected subgraph for level computation.
    # Strip dependencies to non-affected tasks so compute_levels doesn't stall.
    affected_graph =
      graph
      |> Enum.filter(fn {name, _} -> MapSet.member?(affected_names, name) end)
      |> Map.new(fn {name, task} ->
        trimmed_deps = Enum.filter(task.depends_on || [], &MapSet.member?(affected_names, &1))
        {name, %{task | depends_on: trimmed_deps}}
      end)

    # Cache predictions for affected tasks
    cache_predictions = predict_cache(affected_graph, path)

    # Execution levels for affected tasks only
    levels = Explain.compute_levels(affected_graph)
    blocks = Explain.compute_blocks(affected_graph)
    duration_map = build_duration_map(run_history)
    critical_path = Explain.compute_critical_path(affected_graph, duration_map)

    # Build affected task details
    affected_lookup = Map.new(affected, fn a -> {a.name, a} end)

    plan_tasks =
      affected_graph
      |> Enum.map(fn {name, task} ->
        affected_info = Map.get(affected_lookup, name, %{reason: :always, files: []})
        cache_info = Map.get(cache_predictions, name, %{cached: false, reason: nil})
        task_blocks = Map.get(blocks, name, []) |> Enum.sort()

        level =
          levels
          |> Enum.find_value(fn {lvl, names} ->
            if name in names, do: lvl
          end) || 0

        reason_str = format_reason(affected_info.reason)
        triggered_by = Map.get(affected_info, :files, [])

        base = %{
          name: name,
          command: task.command,
          reason: reason_str,
          triggered_by: triggered_by,
          cached: cache_info.cached,
          cache_reason: if(cache_info.reason, do: Atom.to_string(cache_info.reason)),
          level: level,
          depends_on: Task.depends_on(task),
          blocks: task_blocks
        }

        # Add depends_on_affected for dependent tasks
        if affected_info.reason == :dependent do
          Map.put(base, :depends_on_affected, affected_info.depends_on)
        else
          base
        end
      end)
      |> Enum.sort_by(& &1.level)

    # Compute skipped tasks
    skipped =
      graph
      |> Enum.reject(fn {name, _} -> MapSet.member?(affected_names, name) end)
      |> Enum.map(fn {name, _} -> %{name: name, reason: "no inputs changed"} end)
      |> Enum.sort_by(& &1.name)

    # Changed files
    changed_files =
      case Delta.get_changed_files(from, path) do
        {:ok, files} -> files
        _ -> []
      end

    # Execution levels formatted
    execution_levels =
      levels
      |> Enum.sort_by(fn {level, _} -> level end)
      |> Enum.map(fn {level, names} -> %{level: level, tasks: Enum.sort(names)} end)

    estimated_duration_ms = estimate_duration(levels, duration_map)

    max_parallelism =
      levels
      |> Enum.map(fn {_level, names} -> length(names) end)
      |> Enum.max(fn -> 0 end)

    %{
      version: @schema_version,
      from: from,
      changed_files: changed_files,
      plan: %{
        task_count: length(plan_tasks),
        tasks: plan_tasks,
        execution_levels: execution_levels,
        critical_path: critical_path,
        estimated_duration_ms: estimated_duration_ms,
        parallelism: max_parallelism
      },
      skipped: skipped
    }
  end

  defp format_reason(:direct), do: "direct"
  defp format_reason(:dependent), do: "dependent"
  defp format_reason(other), do: to_string(other)

  defp build_duration_map(nil), do: %{}

  defp build_duration_map(%{tasks: tasks}) do
    Map.new(tasks, fn t -> {t.name, t.duration_ms || 1000} end)
  end

  defp build_duration_map(_), do: %{}

  defp estimate_duration(levels, duration_map) do
    levels
    |> Enum.map(fn {_level, names} ->
      names
      |> Enum.map(&Map.get(duration_map, &1, 1000))
      |> Enum.max(fn -> 0 end)
    end)
    |> Enum.sum()
  end
end
