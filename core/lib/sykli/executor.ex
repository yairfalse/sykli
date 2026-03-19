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

  alias Sykli.Error
  alias Sykli.Executor.Output
  alias Sykli.Occurrence.PubSub, as: OccPubSub
  alias Sykli.Services.ArtifactResolver
  alias Sykli.Services.CacheService
  alias Sykli.Services.ConditionService
  alias Sykli.Services.OIDCService
  alias Sykli.Services.PredictiveWarnings
  alias Sykli.Services.ProgressTracker
  alias Sykli.Services.SecretValidator

  # Note: we DON'T alias Sykli.Graph.Task because it shadows Elixir's Task module
  # Use full path: %Sykli.Graph.Task{}

  defmodule TaskResult do
    @moduledoc """
    Result of executing a single task.

    Status values:
    - `:passed` - Task ran and succeeded
    - `:failed` - Task ran and its command failed (non-zero exit code)
    - `:errored` - Task failed due to infrastructure (crash, timeout, missing secrets, OIDC)
    - `:cached` - Task was skipped due to cache hit
    - `:skipped` - Task was skipped due to condition not met
    - `:blocked` - Task didn't run because a dependency failed
    """

    @enforce_keys [:name, :status, :duration_ms]
    defstruct [:name, :status, :duration_ms, :error, :output]

    @type status :: :passed | :failed | :errored | :cached | :skipped | :blocked
    @type t :: %__MODULE__{
            name: String.t(),
            status: status(),
            duration_ms: non_neg_integer(),
            error: term() | nil,
            output: String.t() | nil
          }
  end

  defmodule Config do
    @moduledoc "Executor configuration to avoid parameter explosion."

    defstruct [
      :target,
      :timeout,
      :run_id,
      max_parallel: :infinity,
      continue_on_failure: false
    ]

    @type t :: %__MODULE__{
            target: module(),
            timeout: pos_integer(),
            run_id: String.t() | nil,
            max_parallel: pos_integer() | :infinity,
            continue_on_failure: boolean()
          }
  end

  @default_target Sykli.Target.Local

  # 5 minutes
  @default_timeout 300_000

  def run(tasks, graph, opts \\ []) do
    # Support both :target (new) and :executor (legacy for Mesh)
    target = Keyword.get(opts, :target) || Keyword.get(opts, :executor, @default_target)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    run_id = Keyword.get(opts, :run_id)
    max_parallel = Keyword.get(opts, :max_parallel, :infinity)
    continue_on_failure = Keyword.get(opts, :continue_on_failure, false)
    start_time = System.monotonic_time(:millisecond)
    total_tasks = length(tasks)

    config = %Config{
      target: target,
      timeout: timeout,
      run_id: run_id,
      max_parallel: max_parallel,
      continue_on_failure: continue_on_failure
    }

    # Validate artifact graph BEFORE executing anything
    # This catches issues like missing outputs or invalid dependencies early
    case Sykli.Graph.validate_artifacts(graph) do
      {:error, reason} ->
        error = Error.artifact_error(reason)
        Output.error(error)
        {:error, error}

      :ok ->
        # Setup target with all options
        do_run(tasks, graph, config, opts, start_time, total_tasks)
    end
  end

  defp do_run(tasks, graph, %Config{} = config, opts, start_time, _total_tasks) do
    case config.target.setup(opts) do
      {:ok, state} ->
        try do
          # Apply select hooks to filter tasks
          tasks = apply_select_hooks(tasks, graph, config)
          total_tasks = length(tasks)

          # Emit predictive warnings based on history hints (non-blocking)
          graph |> PredictiveWarnings.scan() |> PredictiveWarnings.print_warnings()

          # Group tasks by "level" - tasks at same level can run in parallel
          levels = group_by_level(tasks, graph)

          # Execute level by level, collecting results with timing
          result = run_levels(levels, state, [], {0, total_tasks}, graph, config)

          # Print summary with status graph
          total_time = System.monotonic_time(:millisecond) - start_time
          print_summary(result, total_time, tasks)

          # Return results (run history saved by Sykli.run)
          result
        after
          config.target.teardown(state)
        end

      {:error, reason} ->
        error = Error.internal("target setup failed", cause: reason)
        Output.error(error)
        {:error, error}
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

  defp run_levels([], _state, acc, _progress, _graph, _config),
    do: {:ok, Enum.reverse(acc)}

  defp run_levels(
         [level | rest],
         state,
         acc,
         {completed, total},
         graph,
         %Config{} = config
       ) do
    level_size = length(level)
    next_tasks = rest |> List.flatten() |> Enum.map(& &1.name)

    # Show level header with upcoming tasks
    Output.level_header(level_size, next_tasks)

    # Sort level for adaptive scheduling: critical first, non-flaky, shortest
    sorted_level = sort_level(level)

    # Chunk level tasks for concurrency limiting
    chunks = chunk_tasks(sorted_level, config.max_parallel)

    results = run_level_chunks(chunks, state, completed, total, graph, config)

    new_completed = completed + level_size

    # Check if any failed
    failed_results =
      Enum.filter(results, fn %TaskResult{status: status} -> status in [:failed, :errored] end)

    has_failures = failed_results != []

    if has_failures and not config.continue_on_failure do
      failed = hd(failed_results)
      Output.task_failed_stopping(failed.name)

      # Mark remaining tasks as blocked
      blocked_results = mark_remaining_as_blocked(rest, config.run_id)

      {:error, Enum.reverse(acc) ++ results ++ blocked_results}
    else
      if has_failures and config.continue_on_failure do
        # Track failed task names for transitive blocking
        failed_names =
          failed_results
          |> Enum.map(fn %TaskResult{name: n} -> n end)
          |> MapSet.new()

        all_failed_names =
          (acc ++ results)
          |> Enum.filter(fn %TaskResult{status: s} -> s in [:failed, :errored, :blocked] end)
          |> Enum.map(fn %TaskResult{name: n} -> n end)
          |> MapSet.new()

        # Filter remaining levels: skip tasks transitively blocked by failures
        {rest, blocked} = partition_blocked(rest, all_failed_names, graph)
        blocked_results = mark_remaining_as_blocked([blocked], config.run_id)

        Output.run_continuing(MapSet.size(failed_names))

        run_levels(
          rest,
          state,
          Enum.reverse(results ++ blocked_results) ++ acc,
          {new_completed, total},
          graph,
          config
        )
      else
        # All passed, continue to next level
        run_levels(
          rest,
          state,
          Enum.reverse(results) ++ acc,
          {new_completed, total},
          graph,
          config
        )
      end
    end
  end

  # Execute level tasks in chunks for concurrency limiting
  defp run_level_chunks(chunks, state, completed, total, graph, config) do
    {results, _} =
      Enum.reduce(chunks, {[], completed}, fn chunk, {acc_results, current_completed} ->
        {:ok, tracker} = ProgressTracker.start_link(initial: current_completed, total: total)

        # Capture current group leader so supervised tasks inherit IO destination
        # (needed for capture_io in tests and correct IO routing)
        caller_gl = Process.group_leader()

        async_tasks =
          chunk
          |> Enum.map(fn task ->
            Task.Supervisor.async_nolink(Sykli.TaskSupervisor, fn ->
              Process.group_leader(self(), caller_gl)
              task_num = ProgressTracker.increment(tracker)
              start_time = System.monotonic_time(:millisecond)

              # Resolve task_inputs before running the task
              case resolve_task_inputs(task, graph, state, config.target) do
                :ok ->
                  %TaskResult{} =
                    result =
                    run_single(task, state, {task_num, total}, config.target, config.run_id)

                  duration = System.monotonic_time(:millisecond) - start_time
                  %TaskResult{result | duration_ms: duration}

                {:error, reason} ->
                  duration = System.monotonic_time(:millisecond) - start_time

                  %TaskResult{
                    name: task.name,
                    status: :errored,
                    duration_ms: duration,
                    error: reason
                  }
              end
            end)
          end)

        chunk_results =
          async_tasks
          |> Task.yield_many(:infinity)
          |> Enum.zip(chunk)
          |> Enum.map(fn
            {{_task, {:ok, result}}, _original} ->
              result

            {{task_ref, {:exit, reason}}, original} ->
              Task.shutdown(task_ref, :brutal_kill)

              %TaskResult{
                name: original.name,
                status: :errored,
                duration_ms: 0,
                error: Error.internal("task process crashed: #{inspect(reason)}")
              }

            {{task_ref, nil}, original} ->
              Task.shutdown(task_ref, :brutal_kill)

              %TaskResult{
                name: original.name,
                status: :errored,
                duration_ms: 0,
                error: Error.internal("task process timed out")
              }
          end)

        ProgressTracker.stop(tracker)

        {acc_results ++ chunk_results, current_completed + length(chunk)}
      end)

    results
  end

  # Adaptive scheduling: sort tasks within a level for priority-based execution.
  # Order: critical first → non-flaky before flaky → shortest duration first.
  # Only matters when max_parallel constrains concurrency (tasks are chunked).
  defp sort_level(tasks) do
    Enum.sort_by(tasks, fn task ->
      critical =
        if task.semantic && task.semantic.criticality == :high, do: 0, else: 1

      flaky =
        if task.history_hint && task.history_hint.flaky, do: 1, else: 0

      duration =
        (task.history_hint && task.history_hint.avg_duration_ms) || 1000

      {critical, flaky, duration}
    end)
  end

  defp chunk_tasks(level, :infinity), do: [level]
  defp chunk_tasks(level, n) when is_integer(n) and n > 0, do: Enum.chunk_every(level, n)
  defp chunk_tasks(level, _), do: [level]

  # Partition remaining levels into runnable and blocked by failed tasks.
  # Computes transitive closure: if A fails, B depends on A → blocked,
  # C depends on B → also blocked.
  defp partition_blocked(levels, failed_names, _graph) do
    {runnable_levels, blocked_tasks, expanded_failed} =
      Enum.reduce(levels, {[], [], failed_names}, fn level, {run_acc, block_acc, failed_set} ->
        {runnable, blocked} =
          Enum.split_with(level, fn task ->
            deps = task.depends_on || []
            not Enum.any?(deps, &MapSet.member?(failed_set, &1))
          end)

        # Expand failed set with newly blocked task names for transitivity
        new_failed =
          blocked
          |> Enum.map(& &1.name)
          |> Enum.reduce(failed_set, &MapSet.put(&2, &1))

        run_acc = if runnable != [], do: run_acc ++ [runnable], else: run_acc
        {run_acc, block_acc ++ blocked, new_failed}
      end)

    _ = expanded_failed
    {runnable_levels, blocked_tasks}
  end

  defp mark_remaining_as_blocked(remaining_levels, run_id) do
    remaining_levels
    |> List.flatten()
    |> Enum.map(fn task ->
      maybe_emit_task_skipped(task.name, :dependency_failed, run_id)

      %TaskResult{
        name: task.name,
        status: :blocked,
        duration_ms: 0,
        error: :dependency_failed
      }
    end)
  end

  # ----- AI HOOKS -----

  # Apply select hooks to filter tasks before execution
  defp apply_select_hooks(tasks, _graph, _config) do
    # Get affected task names for :smart selection (lazy, computed once)
    affected =
      lazy_affected_tasks(tasks)

    Enum.filter(tasks, fn task ->
      check_select_hook(task, affected)
    end)
  end

  defp check_select_hook(%Sykli.Graph.Task{ai_hooks: nil} = _task, _affected), do: true

  defp check_select_hook(%Sykli.Graph.Task{ai_hooks: hooks} = task, affected) do
    case hooks.select do
      :smart ->
        case affected do
          {:ok, names} -> task.name in names
          # If delta fails (e.g., not a git repo), run everything
          {:error, _} -> true
        end

      :manual ->
        false

      # :always or nil — run
      _ ->
        true
    end
  end

  defp lazy_affected_tasks(tasks) do
    case Sykli.Delta.affected_tasks(tasks) do
      {:ok, names} -> {:ok, names}
      error -> error
    end
  end

  # Apply on_fail hook to transform result after execution
  defp apply_on_fail_hook(%TaskResult{status: status} = result, %Sykli.Graph.Task{
         ai_hooks: %{on_fail: :skip}
       })
       when status in [:failed, :errored] do
    %TaskResult{result | status: :skipped}
  end

  defp apply_on_fail_hook(result, _task), do: result

  # Boost retry count for on_fail: :retry
  defp apply_on_fail_retry_boost(%Sykli.Graph.Task{ai_hooks: %{on_fail: :retry}} = task) do
    current = task.retry || 0
    %{task | retry: max(current, 2)}
  end

  defp apply_on_fail_retry_boost(task), do: task

  # ----- RUNNING A SINGLE TASK -----

  @spec run_single(
          Sykli.Graph.Task.t(),
          map(),
          {pos_integer(), pos_integer()},
          module(),
          String.t() | nil
        ) ::
          TaskResult.t()
  defp run_single(%Sykli.Graph.Task{} = task, state, progress, target, run_id) do
    start_time = System.monotonic_time(:millisecond)

    # Handle gates (approval points)
    if Sykli.Graph.Task.gate?(task) do
      run_gate(task, state, progress, run_id)
    else
      # Check condition first
      if should_run?(task) do
        # Resolve secret_refs before execution
        task = resolve_secret_refs(task)

        # OIDC credential exchange (if configured)
        try do
          case OIDCService.exchange(task, state) do
            {:ok, oidc_env} ->
              # Merge OIDC env vars into task env
              task =
                if map_size(oidc_env) > 0 do
                  %{task | env: Map.merge(task.env || %{}, oidc_env)}
                else
                  task
                end

              # Validate required secrets are present (via target)
              case validate_secrets(task, state, target) do
                :ok ->
                  run_task_with_cache(task, state, progress, target, start_time, run_id)

                {:error, missing} ->
                  Output.missing_secrets(task.name, missing)

                  duration = System.monotonic_time(:millisecond) - start_time

                  %TaskResult{
                    name: task.name,
                    status: :errored,
                    duration_ms: duration,
                    error: Error.missing_secrets(task.name, missing)
                  }
              end

            {:error, reason} ->
              Output.oidc_failed(task.name, reason)

              duration = System.monotonic_time(:millisecond) - start_time

              %TaskResult{
                name: task.name,
                status: :errored,
                duration_ms: duration,
                error: Error.internal("OIDC credential exchange failed: #{reason}")
              }
          end
        after
          OIDCService.cleanup_temp_files()
        end
      else
        Output.task_skipped("", task.name, "condition not met")

        maybe_emit_task_skipped(task.name, :condition_not_met, run_id)
        duration = System.monotonic_time(:millisecond) - start_time

        %TaskResult{
          name: task.name,
          status: :skipped,
          duration_ms: duration,
          error: nil
        }
      end
    end
  end

  defp run_gate(%Sykli.Graph.Task{} = task, _state, progress, run_id) do
    prefix = progress_prefix(progress)
    gate = Sykli.Graph.Task.gate(task)

    Output.gate_waiting(prefix, task.name, gate.strategy)

    # Emit gate waiting event (run_id may be nil for CLI runs)
    maybe_emit_gate_waiting(run_id, task.name, gate)

    start_time = System.monotonic_time(:millisecond)
    result = Sykli.Services.GateService.wait(gate)
    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:approved, approver} ->
        maybe_emit_gate_resolved(run_id, task.name, :approved, approver, duration)

        Output.gate_approved(prefix, task.name, approver)

        %TaskResult{name: task.name, status: :passed, duration_ms: duration, error: nil}

      {:denied, reason} ->
        maybe_emit_gate_resolved(run_id, task.name, :denied, reason, duration)

        Output.gate_denied(prefix, task.name, reason)

        %TaskResult{
          name: task.name,
          status: :failed,
          duration_ms: duration,
          error: Error.internal("gate '#{task.name}' denied: #{reason}")
        }

      {:timed_out} ->
        maybe_emit_gate_resolved(run_id, task.name, :timed_out, nil, duration)

        Output.gate_timed_out(prefix, task.name, gate.timeout)

        %TaskResult{
          name: task.name,
          status: :failed,
          duration_ms: duration,
          error: Error.internal("gate '#{task.name}' timed out after #{gate.timeout}s")
        }
    end
  end

  @spec run_task_with_cache(
          Sykli.Graph.Task.t(),
          map(),
          {pos_integer(), pos_integer()} | nil,
          module(),
          integer(),
          String.t() | nil
        ) :: TaskResult.t()
  defp run_task_with_cache(
         %Sykli.Graph.Task{} = task,
         state,
         progress,
         target,
         start_time,
         run_id
       ) do
    prefix = progress_prefix(progress)
    workdir = state.workdir

    # Check cache first using CacheService
    case CacheService.check_and_restore(task, workdir) do
      {:hit, cache_key} ->
        Output.task_cached(prefix, task.name)

        maybe_emit_task_cached(task.name, cache_key, run_id)
        maybe_github_status(task.name, "success")
        duration = System.monotonic_time(:millisecond) - start_time

        %TaskResult{
          name: task.name,
          status: :cached,
          duration_ms: duration,
          error: nil
        }

      {:miss, cache_key, reason} ->
        # Show miss reason for visibility
        reason_str = CacheService.format_miss_reason(reason)

        Output.task_starting(prefix, task.name, reason_str)

        maybe_emit_cache_miss(task.name, cache_key, reason_str, run_id)
        run_with_retry(task, state, cache_key, progress, target, start_time, run_id)
    end
  end

  # Run task with retry logic
  @spec run_with_retry(
          Sykli.Graph.Task.t(),
          map(),
          binary() | nil,
          {pos_integer(), pos_integer()} | nil,
          module(),
          integer(),
          String.t() | nil
        ) :: TaskResult.t()
  defp run_with_retry(task, state, cache_key, progress, target, start_time, run_id) do
    # Apply on_fail: :retry boost before calculating max_attempts
    task = apply_on_fail_retry_boost(task)
    max_attempts = (task.retry || 0) + 1

    # Generate a chain_id to correlate retry occurrences for this task
    chain_id = if max_attempts > 1, do: Sykli.ULID.generate(), else: nil

    result =
      do_run_with_retry(
        task,
        state,
        cache_key,
        1,
        max_attempts,
        progress,
        target,
        start_time,
        run_id,
        chain_id
      )

    # Apply on_fail: :skip transformation
    apply_on_fail_hook(result, task)
  end

  @spec do_run_with_retry(
          Sykli.Graph.Task.t(),
          map(),
          binary() | nil,
          pos_integer(),
          pos_integer(),
          {pos_integer(), pos_integer()} | nil,
          module(),
          integer(),
          String.t() | nil,
          String.t() | nil
        ) :: TaskResult.t()
  defp do_run_with_retry(
         task,
         state,
         cache_key,
         attempt,
         max_attempts,
         progress,
         target,
         start_time,
         run_id,
         chain_id
       ) do
    case Sykli.Telemetry.span_task(task.name, %{}, fn ->
           run_and_cache(task, state, cache_key, progress, target)
         end) do
      result when result == :ok or (is_tuple(result) and elem(result, 0) == :ok) ->
        duration = System.monotonic_time(:millisecond) - start_time

        output =
          case result do
            {:ok, out} -> out
            :ok -> nil
          end

        %TaskResult{
          name: task.name,
          status: :passed,
          duration_ms: duration,
          error: nil,
          output: output
        }

      {:error, reason} when attempt < max_attempts ->
        Output.task_retrying(task.name, attempt, max_attempts)

        maybe_emit_task_retrying(task.name, attempt, max_attempts, reason, run_id, chain_id)

        do_run_with_retry(
          task,
          state,
          cache_key,
          attempt + 1,
          max_attempts,
          progress,
          target,
          start_time,
          run_id,
          chain_id
        )

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time

        # Extract output from Sykli.Error if available
        output =
          case reason do
            %Sykli.Error{output: out} when is_binary(out) -> out
            _ -> nil
          end

        %TaskResult{
          name: task.name,
          status: :failed,
          duration_ms: duration,
          error: reason,
          output: output
        }
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
            {:ok, output} ->
              if cache_key do
                Sykli.Cache.store(cache_key, task, outputs || [], duration_ms, workdir)
              end

              maybe_github_status(name, "success")
              {:ok, output}

            :ok ->
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
        Output.service_start_failed(name, reason)
        {:error, {:service_start_failed, reason}}
    end
  end

  defp maybe_github_status(task_name, state) do
    Sykli.SCM.update_status(task_name, state)
  end

  # ----- SECRET REF RESOLUTION -----

  defp resolve_secret_refs(%Sykli.Graph.Task{secret_refs: refs} = task)
       when is_list(refs) and refs != [] do
    resolved =
      Enum.reduce(refs, %{}, fn ref, acc ->
        case resolve_single_secret_ref(ref) do
          {:ok, value} -> Map.put(acc, ref.name, value)
          {:error, _} -> acc
        end
      end)

    %{task | env: Map.merge(task.env || %{}, resolved)}
  end

  defp resolve_secret_refs(task), do: task

  defp resolve_single_secret_ref(%{source: "env", key: key}) do
    case System.get_env(key) do
      nil -> {:error, {:missing_env, key}}
      value -> {:ok, value}
    end
  end

  defp resolve_single_secret_ref(%{source: "file", key: path}) do
    abs_path = Path.expand(path)

    # Block paths outside CWD to prevent path traversal
    # (e.g., reading /etc/shadow or K8s service account tokens).
    # Use trailing slash to prevent prefix tricks (/cwd_evil matching /cwd).
    cwd = File.cwd!()

    if abs_path == cwd or String.starts_with?(abs_path, cwd <> "/") do
      case File.read(abs_path) do
        {:ok, content} -> {:ok, String.trim(content)}
        {:error, reason} -> {:error, {:file_read_failed, path, reason}}
      end
    else
      {:error, {:path_traversal, path}}
    end
  end

  defp resolve_single_secret_ref(_), do: {:error, :unknown_source}

  # ----- SECRET VALIDATION -----

  # Validates that all required secrets are present (via target)
  # Delegates to SecretValidator service
  defp validate_secrets(task, state, target) do
    SecretValidator.validate(task, state, target)
  end

  # ----- OUTPUT NORMALIZATION -----

  # Convert outputs to list format (for cache storage)
  defp normalize_outputs_to_list(nil), do: []
  defp normalize_outputs_to_list(outputs) when is_list(outputs), do: outputs
  defp normalize_outputs_to_list(outputs) when is_map(outputs), do: Map.values(outputs)

  # ----- TASK INPUT RESOLUTION -----

  # Resolve and copy task_inputs (artifact passing between tasks)
  # Delegates to ArtifactResolver service
  defp resolve_task_inputs(task, graph, state, target) do
    ArtifactResolver.resolve(task, graph, state, target)
  end

  # ----- CONDITION EVALUATION -----

  # Check if a task should run based on its condition
  # Delegates to ConditionService
  defp should_run?(task), do: ConditionService.should_run?(task)

  # ----- PROGRESS PREFIX -----

  defp progress_prefix(nil), do: ""

  defp progress_prefix({current, total}) do
    "#{IO.ANSI.faint()}[#{current}/#{total}]#{IO.ANSI.reset()} "
  end

  # ----- SUMMARY -----

  defp print_summary({:ok, results}, total_time, tasks),
    do: Output.summary(results, total_time, :ok, tasks)

  defp print_summary({:error, results}, total_time, tasks),
    do: Output.summary(results, total_time, :error, tasks)

  # ----- GATE EVENT EMISSION -----

  defp maybe_emit_gate_waiting(nil, _name, _gate), do: :ok

  defp maybe_emit_gate_waiting(run_id, name, gate) do
    OccPubSub.gate_waiting(run_id, name, gate.strategy, gate.message, gate.timeout)
  end

  defp maybe_emit_gate_resolved(nil, _name, _outcome, _approver, _duration), do: :ok

  defp maybe_emit_gate_resolved(run_id, name, outcome, approver, duration) do
    OccPubSub.gate_resolved(run_id, name, outcome, approver, duration)
  end

  # ----- OCCURRENCE EMISSION (cache, skip, retry) -----

  defp maybe_emit_task_cached(_task_name, _cache_key, nil), do: :ok

  defp maybe_emit_task_cached(task_name, cache_key, run_id) do
    OccPubSub.task_cached(run_id, task_name, cache_key)
  end

  defp maybe_emit_cache_miss(_task_name, _cache_key, _reason, nil), do: :ok

  defp maybe_emit_cache_miss(task_name, cache_key, reason, run_id) do
    OccPubSub.cache_miss(run_id, task_name, cache_key, reason)
  end

  defp maybe_emit_task_skipped(_task_name, _reason, nil), do: :ok

  defp maybe_emit_task_skipped(task_name, reason, run_id) do
    OccPubSub.task_skipped(run_id, task_name, reason)
  end

  defp maybe_emit_task_retrying(_task_name, _attempt, _max_attempts, _reason, nil, _chain_id),
    do: :ok

  defp maybe_emit_task_retrying(task_name, attempt, max_attempts, reason, run_id, chain_id) do
    OccPubSub.task_retrying(run_id, task_name, attempt, max_attempts,
      error: reason,
      chain_id: chain_id
    )
  end
end
