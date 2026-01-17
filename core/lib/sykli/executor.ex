defmodule Sykli.Executor do
  @moduledoc """
  Orchestrates task execution with parallelism for independent tasks.

  This module handles:
  - DAG-based execution (grouping tasks by dependency level)
  - Parallel execution within each level
  - Caching (check/store)
  - Progress tracking
  - Retry logic

  Actual task execution is delegated to a Target:
  - `Sykli.Target.Local` - Docker/shell (default)
  - `Sykli.Target.K8s` - Kubernetes Jobs (future)

  ## Options

  - `:workdir` - Working directory (default: ".")
  - `:target` - Target module (default: Sykli.Target.Local)
  - `:executor` - Legacy executor module (deprecated, use `:target`)
  """

  # Note: we DON'T alias Sykli.Graph.Task because it shadows Elixir's Task module
  # Use full path: %Sykli.Graph.Task{}

  @default_target Sykli.Target.Local

  # 5 minutes
  @default_timeout 300_000

  def run(tasks, graph, opts \\ []) do
    # Support both :target (new) and :executor (legacy for Mesh)
    target = Keyword.get(opts, :target) || Keyword.get(opts, :executor, @default_target)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    start_time = System.monotonic_time(:millisecond)
    total_tasks = length(tasks)

    # Validate artifact graph BEFORE executing anything
    # This catches issues like missing outputs or invalid dependencies early
    case Sykli.Graph.validate_artifacts(graph) do
      {:error, reason} ->
        IO.puts(
          "#{IO.ANSI.red()}✗ Artifact validation failed: #{format_artifact_error(reason)}#{IO.ANSI.reset()}"
        )

        {:error, {:artifact_validation_failed, reason}}

      :ok ->
        # Setup target with all options
        do_run(tasks, graph, target, opts, timeout, start_time, total_tasks)
    end
  end

  defp do_run(tasks, graph, target, opts, timeout, start_time, total_tasks) do
    case target.setup(opts) do
      {:ok, state} ->
        try do
          # Group tasks by "level" - tasks at same level can run in parallel
          levels = group_by_level(tasks, graph)

          # Execute level by level, collecting results with timing
          # Pass progress state: {completed_count, total_count}
          # Also pass graph for resolving task_inputs
          result = run_levels(levels, state, [], {0, total_tasks}, graph, target, timeout)

          # Print summary with status graph
          total_time = System.monotonic_time(:millisecond) - start_time
          print_summary(result, total_time, tasks)

          # Return original format
          case result do
            {:ok, results} -> {:ok, results}
            {:error, results} -> {:error, results}
          end
        after
          target.teardown(state)
        end

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}✗ Target setup failed: #{inspect(reason)}#{IO.ANSI.reset()}")
        {:error, {:target_setup_failed, reason}}
    end
  end

  # ----- GROUPING TASKS BY DEPENDENCY LEVEL -----

  # Tasks with no deps = level 0
  # Tasks depending only on level 0 = level 1
  # etc.

  @doc """
  Groups tasks by their dependency level for parallel execution.

  Tasks at the same level have no dependencies on each other and can
  run in parallel. Level 0 tasks have no dependencies, level 1 tasks
  depend only on level 0, etc.

  Returns a list of lists, where each inner list is a "level" of tasks
  that can run concurrently.
  """
  def group_by_level(tasks, graph) do
    # Start with all tasks at level 0
    task_names = Enum.map(tasks, & &1.name)

    # Calculate level for each task
    levels =
      task_names
      |> Enum.map(fn name -> {name, calc_level(name, graph, %{})} end)
      |> Map.new()

    # Group by level, return list of lists
    tasks
    |> Enum.group_by(fn task -> Map.get(levels, task.name, 0) end)
    |> Enum.sort_by(fn {level, _} -> level end)
    |> Enum.map(fn {_level, level_tasks} -> level_tasks end)
  end

  # Recursive level calculation:
  # level = max(level of all dependencies) + 1
  # base case: no deps = level 0
  defp calc_level(name, graph, cache) do
    if Map.has_key?(cache, name) do
      cache[name]
    else
      task = Map.get(graph, name)
      deps = if task, do: task.depends_on, else: []

      if deps == [] do
        0
      else
        deps
        |> Enum.map(&calc_level(&1, graph, cache))
        |> Enum.max()
        |> Kernel.+(1)
      end
    end
  end

  # ----- EXECUTING LEVELS -----

  defp run_levels([], _state, acc, _progress, _graph, _target, _timeout),
    do: {:ok, Enum.reverse(acc)}

  defp run_levels([level | rest], state, acc, {completed, total}, graph, target, timeout) do
    level_size = length(level)
    next_tasks = rest |> List.flatten() |> Enum.map(& &1.name)

    # Show level header with upcoming tasks
    IO.puts(
      "\n#{IO.ANSI.faint()}── Level with #{level_size} task(s)#{if level_size > 1, do: " (parallel)", else: ""} ──#{IO.ANSI.reset()}"
    )

    if length(next_tasks) > 0 do
      IO.puts(
        "#{IO.ANSI.faint()}   next → #{Enum.join(Enum.take(next_tasks, 3), ", ")}#{if length(next_tasks) > 3, do: " +#{length(next_tasks) - 3} more", else: ""}#{IO.ANSI.reset()}"
      )
    end

    # THIS IS THE PARALLEL BIT!
    # Task.async spawns a new process for each task
    # Task.await_many waits for all to complete

    # Create a counter agent for progress tracking
    {:ok, counter} = Agent.start_link(fn -> completed end)

    async_tasks =
      level
      |> Enum.map(fn task ->
        Task.async(fn ->
          # Get and increment counter
          task_num = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
          start_time = System.monotonic_time(:millisecond)
          # Resolve task_inputs before running the task
          case resolve_task_inputs(task, graph, state, target) do
            :ok ->
              result = run_single(task, state, {task_num, total}, target)
              duration = System.monotonic_time(:millisecond) - start_time
              {task.name, result, duration}

            {:error, reason} ->
              duration = System.monotonic_time(:millisecond) - start_time
              {task.name, {:error, reason}, duration}
          end
        end)
      end)

    # Wait for all tasks in this level
    results = Task.await_many(async_tasks, timeout)
    Agent.stop(counter)

    new_completed = completed + level_size

    # Check if any failed
    failed = Enum.find(results, fn {_name, status, _duration} -> status != :ok end)

    if failed do
      {name, {:error, _reason}, _duration} = failed
      IO.puts("#{IO.ANSI.red()}✗ #{name} failed, stopping#{IO.ANSI.reset()}")
      {:error, Enum.reverse(acc) ++ results}
    else
      # Continue to next level
      run_levels(
        rest,
        state,
        Enum.reverse(results) ++ acc,
        {new_completed, total},
        graph,
        target,
        timeout
      )
    end
  end

  # ----- RUNNING A SINGLE TASK -----

  defp run_single(%Sykli.Graph.Task{} = task, state, progress, target) do
    # Check condition first
    if should_run?(task) do
      # Validate required secrets are present (via target)
      case validate_secrets(task, state, target) do
        :ok ->
          run_task_with_cache(task, state, progress, target)

        {:error, missing} ->
          IO.puts(
            "#{IO.ANSI.red()}✗ #{task.name}#{IO.ANSI.reset()} " <>
              "#{IO.ANSI.faint()}(missing secrets: #{Enum.join(missing, ", ")})#{IO.ANSI.reset()}"
          )

          {:error, {:missing_secrets, missing}}
      end
    else
      IO.puts(
        "#{IO.ANSI.faint()}○ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(skipped: condition not met)#{IO.ANSI.reset()}"
      )

      :ok
    end
  end

  defp run_task_with_cache(%Sykli.Graph.Task{} = task, state, progress, target) do
    prefix = progress_prefix(progress)
    workdir = state.workdir

    # Check cache first (with detailed reason)
    case Sykli.Cache.check_detailed(task, workdir) do
      {:hit, key} ->
        # Restore outputs from cache
        case Sykli.Cache.restore(key, workdir) do
          :ok ->
            IO.puts(
              "#{prefix}#{IO.ANSI.yellow()}⊙ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}CACHED#{IO.ANSI.reset()}"
            )

            maybe_github_status(task.name, "success")
            :ok

          {:error, reason} ->
            IO.puts(
              "#{prefix}#{IO.ANSI.yellow()}⚠ Cache restore failed for #{task.name}: #{inspect(reason)}#{IO.ANSI.reset()}"
            )

            run_with_retry(task, state, nil, progress, target)
        end

      {:miss, cache_key, reason} ->
        # Show miss reason for visibility
        reason_str = Sykli.Cache.format_miss_reason(reason)

        IO.puts(
          "#{prefix}#{IO.ANSI.cyan()}▶ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(#{reason_str})#{IO.ANSI.reset()}"
        )

        run_with_retry(task, state, cache_key, progress, target)
    end
  end

  # Run task with retry logic
  defp run_with_retry(task, state, cache_key, progress, target) do
    max_attempts = (task.retry || 0) + 1
    do_run_with_retry(task, state, cache_key, 1, max_attempts, progress, target)
  end

  defp do_run_with_retry(task, state, cache_key, attempt, max_attempts, progress, target) do
    case run_and_cache(task, state, cache_key, progress, target) do
      :ok ->
        :ok

      {:error, _reason} when attempt < max_attempts ->
        IO.puts(
          "#{IO.ANSI.yellow()}↻ #{task.name}#{IO.ANSI.reset()} " <>
            "#{IO.ANSI.faint()}(retry #{attempt}/#{max_attempts - 1})#{IO.ANSI.reset()}"
        )

        do_run_with_retry(task, state, cache_key, attempt + 1, max_attempts, progress, target)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_and_cache(
         %Sykli.Graph.Task{name: name, outputs: outputs_raw, services: services} = task,
         state,
         cache_key,
         progress,
         target
       ) do
    workdir = state.workdir

    # Convert outputs to list of paths for cache storage (handle both map and list formats)
    outputs = normalize_outputs_to_list(outputs_raw)

    # Start services if any (via target)
    case target.start_services(name, services || [], state) do
      {:ok, network_info} ->
        try do
          # Post pending status to GitHub
          maybe_github_status(name, "pending")

          # Track execution time
          start_time = System.monotonic_time(:millisecond)

          # Extract network name for job execution
          network =
            case network_info do
              {net, _containers, _runtime} -> net
              {net, _containers} -> net
              _ -> nil
            end

          # Run task via target
          run_opts = [workdir: workdir, network: network, progress: progress]
          result = target.run_task(task, state, run_opts)

          duration_ms = System.monotonic_time(:millisecond) - start_time

          case result do
            :ok ->
              # Store in cache with outputs
              if cache_key do
                Sykli.Cache.store(cache_key, task, outputs || [], duration_ms, workdir)
              end

              maybe_github_status(name, "success")
              :ok

            {:error, reason} ->
              maybe_github_status(name, "failure")
              {:error, reason}
          end
        after
          # Always stop services, even on failure
          target.stop_services(network_info, state)
        end

      {:error, reason} ->
        IO.puts(
          "#{IO.ANSI.red()}✗ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(service start failed: #{inspect(reason)})#{IO.ANSI.reset()}"
        )

        {:error, {:service_start_failed, reason}}
    end
  end

  defp maybe_github_status(task_name, state) do
    if Sykli.GitHub.enabled?() do
      Sykli.GitHub.update_status(task_name, state)
    end
  end

  # ----- SECRET VALIDATION -----

  # Validates that all required secrets are present (via target)
  defp validate_secrets(%Sykli.Graph.Task{secrets: nil}, _state, _target), do: :ok
  defp validate_secrets(%Sykli.Graph.Task{secrets: []}, _state, _target), do: :ok

  defp validate_secrets(%Sykli.Graph.Task{secrets: secrets}, state, target) do
    missing =
      secrets
      |> Enum.filter(fn name ->
        case target.resolve_secret(name, state) do
          {:ok, _} -> false
          {:error, _} -> true
        end
      end)

    if missing == [] do
      :ok
    else
      {:error, missing}
    end
  end

  # ----- OUTPUT NORMALIZATION -----

  # Convert outputs to list format (for cache storage)
  defp normalize_outputs_to_list(nil), do: []
  defp normalize_outputs_to_list(outputs) when is_list(outputs), do: outputs
  defp normalize_outputs_to_list(outputs) when is_map(outputs), do: Map.values(outputs)

  # Convert outputs to map format (for artifact lookup by name)
  defp normalize_outputs_to_map(nil), do: %{}
  defp normalize_outputs_to_map(outputs) when is_map(outputs), do: outputs

  defp normalize_outputs_to_map(outputs) when is_list(outputs) do
    outputs
    |> Enum.with_index()
    |> Map.new(fn {path, idx} -> {"output_#{idx}", path} end)
  end

  # ----- TASK INPUT RESOLUTION -----

  # Resolve and copy task_inputs (artifact passing between tasks)
  defp resolve_task_inputs(%Sykli.Graph.Task{task_inputs: nil}, _graph, _state, _target),
    do: :ok

  defp resolve_task_inputs(%Sykli.Graph.Task{task_inputs: []}, _graph, _state, _target),
    do: :ok

  defp resolve_task_inputs(
         %Sykli.Graph.Task{name: task_name, task_inputs: task_inputs},
         graph,
         state,
         target
       ) do
    results =
      task_inputs
      |> Enum.map(fn %Sykli.Graph.TaskInput{from_task: from_task, output: output_name, dest: dest} ->
        resolve_single_input(
          task_name,
          from_task,
          output_name,
          dest,
          graph,
          state,
          target
        )
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      error -> error
    end
  end

  defp resolve_single_input(task_name, from_task, output_name, dest, graph, state, target) do
    workdir = state.workdir

    # Find the source task
    case Map.get(graph, from_task) do
      nil ->
        IO.puts(
          "#{IO.ANSI.red()}✗ #{task_name}: source task '#{from_task}' not found#{IO.ANSI.reset()}"
        )

        {:error, {:source_task_not_found, from_task}}

      source_task ->
        # Find the output path by name (normalize to map format)
        outputs = normalize_outputs_to_map(source_task.outputs)

        case Map.get(outputs, output_name) do
          nil ->
            IO.puts(
              "#{IO.ANSI.red()}✗ #{task_name}: output '#{output_name}' not found in task '#{from_task}'#{IO.ANSI.reset()}"
            )

            {:error, {:output_not_found, from_task, output_name}}

          source_path ->
            # Copy artifact via target
            case target.copy_artifact(source_path, dest, workdir, state) do
              :ok ->
                IO.puts("  #{IO.ANSI.faint()}← #{source_path} → #{dest}#{IO.ANSI.reset()}")
                :ok

              {:error, reason} ->
                IO.puts(
                  "#{IO.ANSI.red()}✗ #{task_name}: failed to copy #{source_path}: #{inspect(reason)}#{IO.ANSI.reset()}"
                )

                {:error, {:copy_failed, source_path, reason}}
            end
        end
    end
  end

  # ----- CONDITION EVALUATION -----

  # Check if a task should run based on its condition
  defp should_run?(%Sykli.Graph.Task{condition: nil}), do: true
  defp should_run?(%Sykli.Graph.Task{condition: ""}), do: true

  defp should_run?(%Sykli.Graph.Task{condition: condition}) do
    context = build_context()
    evaluate_condition(condition, context)
  end

  # Build context from environment variables (CI systems set these)
  defp build_context do
    %{
      # GitHub Actions
      "branch" => get_branch(),
      "tag" => System.get_env("GITHUB_REF_TYPE") == "tag" && get_ref_name(),
      "event" => System.get_env("GITHUB_EVENT_NAME"),
      "pr_number" => System.get_env("GITHUB_PR_NUMBER"),
      # Generic CI
      "ci" => System.get_env("CI") == "true"
    }
  end

  defp get_branch do
    cond do
      # GitHub Actions
      ref = System.get_env("GITHUB_REF_NAME") ->
        if System.get_env("GITHUB_REF_TYPE") == "branch", do: ref, else: nil

      # GitLab CI
      branch = System.get_env("CI_COMMIT_BRANCH") ->
        branch

      # Generic / local - try git (with timeout)
      true ->
        task =
          Task.async(fn ->
            System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true)
          end)

        case Task.yield(task, 5_000) || Task.shutdown(task) do
          {:ok, {branch, 0}} -> String.trim(branch)
          _ -> nil
        end
    end
  end

  defp get_ref_name do
    System.get_env("GITHUB_REF_NAME") || System.get_env("CI_COMMIT_TAG")
  end

  # Evaluate a condition expression against context using safe evaluator
  # Allows: branch == "main", tag != "", ci and branch == "main"
  defp evaluate_condition(condition, context) do
    # Convert context map to atom-keyed map for evaluator
    eval_context = %{
      branch: context["branch"],
      tag: context["tag"] || "",
      event: context["event"],
      pr_number: context["pr_number"],
      ci: context["ci"] || false
    }

    case Sykli.ConditionEvaluator.evaluate(condition, eval_context) do
      {:ok, result} ->
        !!result

      {:error, reason} ->
        IO.puts(
          "#{IO.ANSI.yellow()}⚠ Invalid condition: #{condition} (#{reason})#{IO.ANSI.reset()}"
        )

        # On error, skip the task (safer than running)
        false
    end
  end

  # ----- PROGRESS PREFIX -----

  defp progress_prefix(nil), do: ""

  defp progress_prefix({current, total}) do
    "#{IO.ANSI.faint()}[#{current}/#{total}]#{IO.ANSI.reset()} "
  end

  # ----- DURATION FORMATTING -----

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  # ----- SUMMARY -----

  defp print_summary({:ok, results}, total_time, tasks),
    do: do_print_summary(results, total_time, :ok, tasks)

  defp print_summary({:error, results}, total_time, tasks),
    do: do_print_summary(results, total_time, :error, tasks)

  defp do_print_summary(results, total_time, status, tasks) do
    if Enum.empty?(results) do
      :ok
    else
      IO.puts("\n#{IO.ANSI.faint()}─────────────────────────────────────────#{IO.ANSI.reset()}")

      # Show status graph
      result_map = build_result_map(results, tasks)
      task_maps = Enum.map(tasks, fn t -> %{name: t.name, depends_on: t.depends_on || []} end)
      IO.puts(Sykli.GraphViz.to_status_line(task_maps, result_map))
      IO.puts("")

      # Count results
      passed = Enum.count(results, fn {_name, result, _duration} -> result == :ok end)
      failed = Enum.count(results, fn {_name, result, _duration} -> result != :ok end)

      # Status icon
      {icon, color} = if status == :ok, do: {"✓", IO.ANSI.green()}, else: {"✗", IO.ANSI.red()}

      IO.puts(
        "#{color}#{icon}#{IO.ANSI.reset()} " <>
          "#{IO.ANSI.bright()}#{passed} passed#{IO.ANSI.reset()}" <>
          if(failed > 0, do: ", #{IO.ANSI.red()}#{failed} failed#{IO.ANSI.reset()}", else: "") <>
          " #{IO.ANSI.faint()}in #{format_duration(total_time)}#{IO.ANSI.reset()}"
      )

      # Show slowest tasks if there are more than 3
      if length(results) > 3 do
        slowest =
          results
          |> Enum.filter(fn {_name, result, _duration} -> result == :ok end)
          |> Enum.sort_by(fn {_name, _result, duration} -> -duration end)
          |> Enum.take(3)

        if length(slowest) > 0 do
          IO.puts("")
          IO.puts("#{IO.ANSI.faint()}Slowest:#{IO.ANSI.reset()}")

          Enum.each(slowest, fn {name, _result, duration} ->
            IO.puts("  #{IO.ANSI.faint()}#{format_duration(duration)}#{IO.ANSI.reset()} #{name}")
          end)
        end
      end

      IO.puts("")
    end
  end

  # Build a map of task_name => status for the graph visualization
  defp build_result_map(results, tasks) do
    # Map results to statuses
    result_statuses =
      results
      |> Enum.map(fn {name, result, _duration} ->
        status = if result == :ok, do: :passed, else: :failed
        {name, status}
      end)
      |> Map.new()

    # Find tasks that weren't run (skipped)
    all_task_names = MapSet.new(tasks, & &1.name)
    run_task_names = MapSet.new(results, fn {name, _, _} -> name end)
    skipped = MapSet.difference(all_task_names, run_task_names)

    # Add skipped tasks
    Enum.reduce(skipped, result_statuses, fn name, acc ->
      Map.put(acc, name, :skipped)
    end)
  end

  # ----- ARTIFACT VALIDATION ERROR FORMATTING -----

  defp format_artifact_error({:source_task_not_found, task, source}) do
    "Task '#{task}' requires artifact from '#{source}', but '#{source}' doesn't exist"
  end

  defp format_artifact_error({:output_not_found, task, source, output}) do
    "Task '#{task}' requires output '#{output}' from '#{source}', but '#{source}' doesn't declare it"
  end

  defp format_artifact_error({:missing_task_dependency, task, source}) do
    "Task '#{task}' requires artifact from '#{source}', but doesn't depend on it. " <>
      "Add '#{source}' to depends_on to ensure ordering."
  end

  defp format_artifact_error(reason), do: inspect(reason)
end
