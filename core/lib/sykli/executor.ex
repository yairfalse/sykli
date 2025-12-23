defmodule Sykli.Executor do
  @moduledoc """
  Executes tasks with parallelism for independent tasks.
  Supports both direct execution and container-based execution (v2).
  """

  # Note: we DON'T alias Sykli.Graph.Task because it shadows Elixir's Task module
  # Use full path: %Sykli.Graph.Task{}

  def run(tasks, graph, opts \\ []) do
    workdir = Keyword.get(opts, :workdir, ".")
    start_time = System.monotonic_time(:millisecond)
    total_tasks = length(tasks)

    # Group tasks by "level" - tasks at same level can run in parallel
    levels = group_by_level(tasks, graph)

    # Execute level by level, collecting results with timing
    # Pass progress state: {completed_count, total_count}
    # Also pass graph for resolving task_inputs
    result = run_levels(levels, workdir, [], {0, total_tasks}, graph)

    # Print summary
    total_time = System.monotonic_time(:millisecond) - start_time
    print_summary(result, total_time)

    # Return original format
    case result do
      {:ok, results} -> {:ok, results}
      {:error, results} -> {:error, results}
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

  defp run_levels([], _workdir, acc, _progress, _graph), do: {:ok, Enum.reverse(acc)}

  defp run_levels([level | rest], workdir, acc, {completed, total}, graph) do
    level_size = length(level)
    next_tasks = rest |> List.flatten() |> Enum.map(& &1.name)

    # Show level header with upcoming tasks
    IO.puts("\n#{IO.ANSI.faint()}── Level with #{level_size} task(s)#{if level_size > 1, do: " (parallel)", else: ""} ──#{IO.ANSI.reset()}")
    if length(next_tasks) > 0 do
      IO.puts("#{IO.ANSI.faint()}   next → #{Enum.join(Enum.take(next_tasks, 3), ", ")}#{if length(next_tasks) > 3, do: " +#{length(next_tasks) - 3} more", else: ""}#{IO.ANSI.reset()}")
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
          case resolve_task_inputs(task, graph, workdir) do
            :ok ->
              result = run_single(task, workdir, {task_num, total})
              duration = System.monotonic_time(:millisecond) - start_time
              {task.name, result, duration}

            {:error, reason} ->
              duration = System.monotonic_time(:millisecond) - start_time
              {task.name, {:error, reason}, duration}
          end
        end)
      end)

    # Wait for all tasks in this level (5 minute timeout)
    results = Task.await_many(async_tasks, 300_000)
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
      run_levels(rest, workdir, Enum.reverse(results) ++ acc, {new_completed, total}, graph)
    end
  end

  # ----- RUNNING A SINGLE TASK -----

  defp run_single(%Sykli.Graph.Task{} = task, workdir, progress) do
    # Check condition first
    if should_run?(task) do
      # Validate required secrets are present
      case validate_secrets(task) do
        :ok ->
          run_task_with_cache(task, workdir, progress)

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

  defp run_task_with_cache(%Sykli.Graph.Task{} = task, workdir, progress) do
    prefix = progress_prefix(progress)

    # Check cache first
    case Sykli.Cache.check(task, workdir) do
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

            run_with_retry(task, workdir, nil, progress)
        end

      {:miss, cache_key} ->
        run_with_retry(task, workdir, cache_key, progress)
    end
  end

  # Run task with retry logic
  defp run_with_retry(task, workdir, cache_key, progress) do
    max_attempts = (task.retry || 0) + 1
    do_run_with_retry(task, workdir, cache_key, 1, max_attempts, progress)
  end

  defp do_run_with_retry(task, workdir, cache_key, attempt, max_attempts, progress) do
    case run_and_cache(task, workdir, cache_key, progress) do
      :ok ->
        :ok

      {:error, _reason} when attempt < max_attempts ->
        IO.puts(
          "#{IO.ANSI.yellow()}↻ #{task.name}#{IO.ANSI.reset()} " <>
            "#{IO.ANSI.faint()}(retry #{attempt}/#{max_attempts - 1})#{IO.ANSI.reset()}"
        )
        do_run_with_retry(task, workdir, cache_key, attempt + 1, max_attempts, progress)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_and_cache(%Sykli.Graph.Task{name: name, outputs: outputs_raw, services: services, timeout: timeout} = task, workdir, cache_key, progress) do
    # Convert outputs to list of paths for cache storage (handle both map and list formats)
    outputs = normalize_outputs_to_list(outputs_raw)
    prefix = progress_prefix(progress)

    # Start services if any
    {network, service_containers} = start_services(name, services || [])

    # Calculate timeout in milliseconds (default 5 minutes)
    timeout_ms = (timeout || 300) * 1000

    # Get start timestamp
    now = :calendar.local_time()
    {_, {h, m, s}} = now
    timestamp = :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> to_string()

    try do
      # Build the actual command (docker run or direct)
      cmd_tuple = build_command(task, workdir, network)
      display_cmd = elem(cmd_tuple, 2)

      IO.puts("#{prefix}#{IO.ANSI.cyan()}▶ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{timestamp} #{display_cmd}#{IO.ANSI.reset()}")

      # Post pending status to GitHub
      maybe_github_status(name, "pending")

      # Track execution time
      start_time = System.monotonic_time(:millisecond)

      # Run with streaming output (with custom timeout)
      case run_streaming(cmd_tuple, workdir, timeout_ms) do
        {:ok, 0, lines, _output} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          lines_str = if lines > 0, do: " #{lines}L", else: ""
          IO.puts("#{IO.ANSI.green()}✓ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{format_duration(duration_ms)}#{lines_str}#{IO.ANSI.reset()}")

          # Store in cache with outputs
          if cache_key do
            Sykli.Cache.store(cache_key, task, outputs || [], duration_ms, workdir)
          end

          maybe_github_status(name, "success")
          :ok

        {:ok, code, _lines, output} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time

          # Show structured error with full context
          error = Sykli.TaskError.new(
            task: name,
            command: display_cmd,
            exit_code: code,
            output: output,
            duration_ms: duration_ms
          )
          IO.puts(Sykli.TaskError.format(error))

          maybe_github_status(name, "failure")
          {:error, {:exit_code, code}}

        {:error, :timeout} ->
          IO.puts("#{IO.ANSI.red()}✗ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(timeout after #{timeout}s)#{IO.ANSI.reset()}")
          IO.puts("  #{IO.ANSI.yellow()}Increase timeout or check if task is stuck#{IO.ANSI.reset()}")
          maybe_github_status(name, "failure")
          {:error, :timeout}

        {:error, reason} ->
          IO.puts("#{IO.ANSI.red()}✗ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(error: #{inspect(reason)})#{IO.ANSI.reset()}")
          maybe_github_status(name, "failure")
          {:error, reason}
      end
    after
      # Always stop services, even on failure
      stop_services(network, service_containers)
    end
  end

  # ----- SERVICE LIFECYCLE -----

  # Start service containers and create network
  # Returns {network_name | nil, [container_ids]}
  defp start_services(_task_name, []), do: {nil, []}
  defp start_services(task_name, services) do
    docker_path = System.find_executable("docker") || "/usr/bin/docker"
    network_name = "sykli-#{sanitize_volume_name(task_name)}-#{:rand.uniform(100_000)}"

    # Create network
    {_, 0} = System.cmd(docker_path, ["network", "create", network_name], stderr_to_stdout: true)
    IO.puts("  #{IO.ANSI.faint()}Created network #{network_name}#{IO.ANSI.reset()}")

    # Start each service
    container_ids =
      Enum.map(services, fn %Sykli.Graph.Service{image: image, name: name} ->
        container_name = "#{network_name}-#{name}"

        # Run container detached on the network
        {output, 0} = System.cmd(docker_path, [
          "run", "-d",
          "--name", container_name,
          "--network", network_name,
          "--network-alias", name,
          image
        ], stderr_to_stdout: true)

        container_id = String.trim(output)
        IO.puts("  #{IO.ANSI.faint()}Started service #{name} (#{image})#{IO.ANSI.reset()}")
        container_id
      end)

    # Give services a moment to start
    if length(services) > 0 do
      Process.sleep(1000)
    end

    {network_name, container_ids}
  end

  # Stop service containers and remove network
  defp stop_services(nil, []), do: :ok
  defp stop_services(network_name, container_ids) do
    docker_path = System.find_executable("docker") || "/usr/bin/docker"

    # Stop and remove containers
    Enum.each(container_ids, fn container_id ->
      System.cmd(docker_path, ["rm", "-f", container_id], stderr_to_stdout: true)
    end)

    # Remove network
    if network_name do
      System.cmd(docker_path, ["network", "rm", network_name], stderr_to_stdout: true)
      IO.puts("  #{IO.ANSI.faint()}Removed network #{network_name}#{IO.ANSI.reset()}")
    end

    :ok
  end

  # ----- COMMAND BUILDING -----

  # Build the command to run - returns {:shell, cmd} or {:docker, args}
  defp build_command(%Sykli.Graph.Task{container: nil, command: command}, _workdir, _network) do
    # No container - run directly via shell
    {:shell, command, command}
  end

  defp build_command(%Sykli.Graph.Task{} = task, workdir, network) do
    # Container task - build docker args list (no shell escaping needed)
    abs_workdir = Path.expand(workdir)

    docker_args = ["run", "--rm"]

    # Connect to network if services are running
    network_args =
      if network do
        ["--network", network]
      else
        []
      end

    # Add volume mounts
    mount_args =
      (task.mounts || [])
      |> Enum.flat_map(fn mount ->
        case mount.type do
          "directory" ->
            host_path = extract_host_path(mount.resource, abs_workdir)
            ["-v", "#{host_path}:#{mount.path}"]

          "cache" ->
            volume_name = "sykli-cache-#{sanitize_volume_name(mount.resource)}"
            ["-v", "#{volume_name}:#{mount.path}"]

          _ ->
            []
        end
      end)

    # Add workdir
    workdir_args =
      if task.workdir do
        ["-w", task.workdir]
      else
        []
      end

    # Add environment variables (passed directly to docker, no shell escaping needed)
    env_args =
      (task.env || %{})
      |> Enum.flat_map(fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    # Build args list - each arg passed directly to docker (no shell injection possible)
    all_args = docker_args ++ network_args ++ mount_args ++ workdir_args ++ env_args ++
               [task.container, "sh", "-c", task.command]

    display = "[#{task.container}] #{task.command}"
    {:docker, all_args, display}
  end

  # Sanitize volume name to only allow alphanumeric, dash, underscore
  defp sanitize_volume_name(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
  end

  # Extract host path from resource ID
  # "src:." -> "."
  # "src:/path/to/dir" -> "/path/to/dir"
  defp extract_host_path(resource, abs_workdir) do
    case String.split(resource, ":", parts: 2) do
      ["src", path] ->
        # Expand and normalize the path to prevent traversal
        full_path = if String.starts_with?(path, "/") do
          path
        else
          Path.join(abs_workdir, path)
        end
        # Expand to resolve .. and normalize
        Path.expand(full_path)

      _ ->
        abs_workdir
    end
  end

  # Run command with streaming output to console
  defp run_streaming({:shell, command, _display}, workdir, timeout_ms) do
    # Shell command - use Port with sh -c
    port = Port.open(
      {:spawn_executable, "/bin/sh"},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", command],
        cd: workdir
      ]
    )

    try do
      stream_output(port, timeout_ms)
    after
      safe_port_close(port)
    end
  end

  defp run_streaming({:docker, args, _display}, workdir, timeout_ms) do
    # Docker command - use Port with docker directly (no shell, no escaping needed)
    docker_path = System.find_executable("docker") || "/usr/bin/docker"

    port = Port.open(
      {:spawn_executable, docker_path},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: workdir
      ]
    )

    try do
      stream_output(port, timeout_ms)
    after
      safe_port_close(port)
    end
  end

  # Safely close a port - it may already be closed when exit_status is received
  defp safe_port_close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  defp stream_output(port, timeout_ms) do
    stream_output(port, timeout_ms, 0, [])
  end

  defp stream_output(port, timeout_ms, line_count, output_acc) do
    receive do
      {^port, {:data, data}} ->
        # Stream output with task prefix
        IO.write("  #{IO.ANSI.faint()}#{data}#{IO.ANSI.reset()}")
        # Count newlines in data
        new_lines = data |> :binary.matches("\n") |> length()
        # Keep last 50 lines for error analysis
        stream_output(port, timeout_ms, line_count + new_lines, [data | output_acc])

      {^port, {:exit_status, status}} ->
        # Combine output (reversed because we prepended)
        full_output = output_acc |> Enum.reverse() |> Enum.join()
        output = String.slice(full_output, -min(String.length(full_output), 4000)..-1//1)
        {:ok, status, line_count, output}
    after
      timeout_ms ->
        safe_port_close(port)
        {:error, :timeout}
    end
  end

  defp maybe_github_status(task_name, state) do
    if Sykli.GitHub.enabled?() do
      Sykli.GitHub.update_status(task_name, state)
    end
  end

  # ----- SECRET VALIDATION -----

  # Validates that all required secrets are present as environment variables
  defp validate_secrets(%Sykli.Graph.Task{secrets: nil}), do: :ok
  defp validate_secrets(%Sykli.Graph.Task{secrets: []}), do: :ok

  defp validate_secrets(%Sykli.Graph.Task{secrets: secrets}) do
    missing =
      secrets
      |> Enum.filter(fn name ->
        case System.get_env(name) do
          nil -> true
          "" -> true
          _ -> false
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
  defp resolve_task_inputs(%Sykli.Graph.Task{task_inputs: nil}, _graph, _workdir), do: :ok
  defp resolve_task_inputs(%Sykli.Graph.Task{task_inputs: []}, _graph, _workdir), do: :ok

  defp resolve_task_inputs(%Sykli.Graph.Task{name: task_name, task_inputs: task_inputs}, graph, workdir) do
    abs_workdir = Path.expand(workdir)

    results =
      task_inputs
      |> Enum.map(fn %Sykli.Graph.TaskInput{from_task: from_task, output: output_name, dest: dest} ->
        resolve_single_input(task_name, from_task, output_name, dest, graph, abs_workdir)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      error -> error
    end
  end

  defp resolve_single_input(task_name, from_task, output_name, dest, graph, workdir) do
    # Find the source task
    case Map.get(graph, from_task) do
      nil ->
        IO.puts("#{IO.ANSI.red()}✗ #{task_name}: source task '#{from_task}' not found#{IO.ANSI.reset()}")
        {:error, {:source_task_not_found, from_task}}

      source_task ->
        # Find the output path by name (normalize to map format)
        outputs = normalize_outputs_to_map(source_task.outputs)

        case Map.get(outputs, output_name) do
          nil ->
            IO.puts("#{IO.ANSI.red()}✗ #{task_name}: output '#{output_name}' not found in task '#{from_task}'#{IO.ANSI.reset()}")
            {:error, {:output_not_found, from_task, output_name}}

          source_path ->
            copy_artifact(source_path, dest, workdir, task_name)
        end
    end
  end

  defp copy_artifact(source_path, dest_path, workdir, task_name) do
    abs_source = Path.join(workdir, source_path)
    abs_dest = Path.join(workdir, dest_path)

    cond do
      File.regular?(abs_source) ->
        # Ensure destination directory exists
        dest_dir = Path.dirname(abs_dest)

        case File.mkdir_p(dest_dir) do
          :ok ->
            case File.copy(abs_source, abs_dest) do
              {:ok, _bytes} ->
                # Preserve executable permissions
                case File.stat(abs_source) do
                  {:ok, %{mode: mode}} -> File.chmod(abs_dest, mode)
                  _ -> :ok
                end
                IO.puts("  #{IO.ANSI.faint()}← #{source_path} → #{dest_path}#{IO.ANSI.reset()}")
                :ok

              {:error, reason} ->
                IO.puts("#{IO.ANSI.red()}✗ #{task_name}: failed to copy #{source_path}: #{inspect(reason)}#{IO.ANSI.reset()}")
                {:error, {:copy_failed, source_path, reason}}
            end

          {:error, reason} ->
            IO.puts("#{IO.ANSI.red()}✗ #{task_name}: failed to create directory #{dest_dir}: #{inspect(reason)}#{IO.ANSI.reset()}")
            {:error, {:mkdir_failed, dest_dir, reason}}
        end

      File.dir?(abs_source) ->
        # Copy entire directory
        case File.mkdir_p(abs_dest) do
          :ok ->
            case File.cp_r(abs_source, abs_dest) do
              {:ok, _} ->
                IO.puts("  #{IO.ANSI.faint()}← #{source_path}/ → #{dest_path}/#{IO.ANSI.reset()}")
                :ok

              {:error, reason, _file} ->
                IO.puts("#{IO.ANSI.red()}✗ #{task_name}: failed to copy directory #{source_path}: #{inspect(reason)}#{IO.ANSI.reset()}")
                {:error, {:copy_failed, source_path, reason}}
            end

          {:error, reason} ->
            IO.puts("#{IO.ANSI.red()}✗ #{task_name}: failed to create directory #{abs_dest}: #{inspect(reason)}#{IO.ANSI.reset()}")
            {:error, {:mkdir_failed, abs_dest, reason}}
        end

      true ->
        IO.puts("#{IO.ANSI.red()}✗ #{task_name}: source file not found: #{source_path}#{IO.ANSI.reset()}")
        {:error, {:source_not_found, source_path}}
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

      # Generic / local - try git
      true ->
        case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true) do
          {branch, 0} -> String.trim(branch)
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

  defp print_summary({:ok, results}, total_time), do: do_print_summary(results, total_time, :ok)
  defp print_summary({:error, results}, total_time), do: do_print_summary(results, total_time, :error)

  defp do_print_summary(results, total_time, status) do
    if Enum.empty?(results) do
      :ok
    else
      IO.puts("\n#{IO.ANSI.faint()}─────────────────────────────────────────#{IO.ANSI.reset()}")

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
end
