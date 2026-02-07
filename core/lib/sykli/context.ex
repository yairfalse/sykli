defmodule Sykli.Context do
  @moduledoc """
  Generates structured context for AI assistants.

  This module creates context files that AI tools can consume to understand
  the project's CI pipeline. The context is designed to be machine-readable
  while providing meaningful semantic information.

  ## Output Files

  - `.sykli/context.json` - Pipeline context with tasks, coverage, and history
  - `.sykli/test-map.json` - Mapping of files to tasks that test them

  ## Usage

      # Generate context after a run
      Sykli.Context.generate(graph, run_result, workdir)

      # Generate test map from graph
      Sykli.Context.generate_test_map(graph, workdir)

  ## Context Structure

      {
        "version": "1.0",
        "generated_at": "2024-01-15T10:30:00Z",
        "pipeline": {
          "task_count": 5,
          "tasks": [...],
          "dependencies": {...}
        },
        "coverage": {
          "file_to_tasks": {...}
        },
        "last_run": {...}
      }
  """

  alias Sykli.Graph.Task
  alias Sykli.Graph.Task.{Semantic, AiHooks, HistoryHint, Capability}
  alias Sykli.Services.MergeQueueDetector

  @context_version "1.0"

  @doc """
  Generates the full context.json file.

  This includes pipeline structure, coverage mapping, and last run results.
  """
  @spec generate(map(), map() | nil, String.t()) :: :ok | {:error, term()}
  def generate(graph, run_result \\ nil, workdir) do
    context =
      %{
        "version" => @context_version,
        "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "pipeline" => build_pipeline_context(graph),
        "coverage" => build_coverage_context(graph),
        "last_run" => build_run_context(run_result)
      }
      |> maybe_add_merge_queue_context()

    write_context_file(context, workdir, "context.json")
  end

  @doc """
  Generates only the test-map.json file.

  Maps files to the tasks that test them, useful for smart task selection.
  """
  @spec generate_test_map(map(), String.t()) :: :ok | {:error, term()}
  def generate_test_map(graph, workdir) do
    test_map = build_file_to_tasks_map(graph)
    write_context_file(test_map, workdir, "test-map.json")
  end

  @doc """
  Gets tasks that should run for given changed files.

  Uses the semantic coverage information to determine which tasks
  are relevant to the changed files.
  """
  @spec tasks_for_changes(map(), [String.t()]) :: [String.t()]
  def tasks_for_changes(graph, changed_files) do
    graph
    |> Enum.filter(fn {_name, task} ->
      semantic = Task.semantic(task)
      hooks = Task.ai_hooks(task)

      cond do
        # Skip manual-only tasks
        hooks.select == :manual -> false
        # Smart tasks: check if covers any changed file
        hooks.select == :smart -> Semantic.covers_any?(semantic, changed_files)
        # Always include non-smart, non-manual tasks (including nil/always)
        true -> true
      end
    end)
    |> Enum.map(fn {name, _task} -> name end)
  end

  @doc """
  Exports a task to a map format suitable for JSON.
  """
  @spec task_to_map(Task.t()) :: map()
  def task_to_map(task) do
    base = %{
      "name" => task.name,
      "command" => task.command,
      "depends_on" => task.depends_on || []
    }

    base
    |> maybe_add_semantic(task)
    |> maybe_add_ai_hooks(task)
    |> maybe_add_history_hint(task)
    |> maybe_add_execution_context(task)
    |> maybe_add_capability(task)
  end

  # Private implementation

  defp build_pipeline_context(graph) do
    tasks =
      graph
      |> Map.values()
      |> Enum.map(&task_to_map/1)

    dependencies =
      graph
      |> Enum.map(fn {name, task} -> {name, task.depends_on || []} end)
      |> Map.new()

    critical_tasks =
      graph
      |> Enum.filter(fn {_name, task} -> Task.critical?(task) end)
      |> Enum.map(fn {name, _task} -> name end)

    %{
      "task_count" => map_size(graph),
      "tasks" => tasks,
      "dependencies" => dependencies,
      "critical_tasks" => critical_tasks
    }
  end

  defp build_coverage_context(graph) do
    %{
      "file_to_tasks" => build_file_to_tasks_map(graph),
      "uncovered_patterns" => find_uncovered_patterns(graph)
    }
  end

  defp build_file_to_tasks_map(graph) do
    graph
    |> Enum.flat_map(fn {name, task} ->
      semantic = Task.semantic(task)

      Enum.map(semantic.covers, fn pattern ->
        {pattern, name}
      end)
    end)
    |> Enum.group_by(fn {pattern, _name} -> pattern end, fn {_pattern, name} -> name end)
  end

  defp find_uncovered_patterns(_graph) do
    # TODO: Compare with actual files in workdir to find uncovered areas
    []
  end

  defp build_run_context(nil), do: nil

  defp build_run_context(run_result) do
    %{
      "timestamp" => run_result[:timestamp] |> format_datetime(),
      "outcome" => to_string(run_result[:outcome] || :unknown),
      "duration_ms" => run_result[:duration_ms],
      "tasks" => Enum.map(run_result[:tasks] || [], &task_result_to_map/1)
    }
  end

  defp task_result_to_map(result) do
    %{
      "name" => result[:name],
      "status" => to_string(result[:status] || :unknown),
      "duration_ms" => result[:duration_ms],
      "cached" => result[:cached] == true,
      "error" => result[:error]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp maybe_add_semantic(map, task) do
    if Task.has_semantic?(task) do
      Map.put(map, "semantic", Semantic.to_map(Task.semantic(task)))
    else
      map
    end
  end

  defp maybe_add_ai_hooks(map, task) do
    if Task.has_ai_hooks?(task) do
      Map.put(map, "ai_hooks", AiHooks.to_map(Task.ai_hooks(task)))
    else
      map
    end
  end

  defp maybe_add_history_hint(map, task) do
    hint = Task.history_hint(task)
    hint_map = HistoryHint.to_map(hint)

    if map_size(hint_map) > 0 do
      Map.put(map, "history_hint", hint_map)
    else
      map
    end
  end

  defp maybe_add_execution_context(map, task) do
    map
    |> maybe_put("container", task.container)
    |> maybe_put("workdir", task.workdir)
    |> maybe_put("timeout", task.timeout)
    |> maybe_put("retry", task.retry)
    |> maybe_put("inputs", non_empty_list(task.inputs))
    |> maybe_put("outputs", non_empty_map(task.outputs))
  end

  defp maybe_add_capability(map, task) do
    cap = task.capability

    if cap != nil do
      cap_map = Capability.to_map(cap)
      if cap_map, do: Map.put(map, "capability", cap_map), else: map
    else
      map
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_empty_list(nil), do: nil
  defp non_empty_list([]), do: nil
  defp non_empty_list(list), do: list

  defp non_empty_map(nil), do: nil
  defp non_empty_map(map) when map_size(map) == 0, do: nil
  defp non_empty_map(map), do: map

  defp maybe_add_merge_queue_context(context) do
    case MergeQueueDetector.detect() do
      {:ok, mq_context} ->
        Map.put(context, "merge_queue", Sykli.MergeQueueContext.to_map(mq_context))

      :not_in_merge_queue ->
        context
    end
  end

  defp write_context_file(content, workdir, filename) do
    dir = Path.join(workdir, ".sykli")
    path = Path.join(dir, filename)

    with :ok <- File.mkdir_p(dir),
         json <- Jason.encode!(content, pretty: true),
         :ok <- File.write(path, json) do
      :ok
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(str) when is_binary(str), do: str
end
