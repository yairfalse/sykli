defmodule Sykli.Executor do
  @moduledoc """
  Executes tasks with parallelism for independent tasks.
  Supports both direct execution and container-based execution (v2).
  """

  # Note: we DON'T alias Sykli.Graph.Task because it shadows Elixir's Task module
  # Use full path: %Sykli.Graph.Task{}

  def run(tasks, graph, opts \\ []) do
    workdir = Keyword.get(opts, :workdir, ".")

    # Group tasks by "level" - tasks at same level can run in parallel
    levels = group_by_level(tasks, graph)

    # Execute level by level
    run_levels(levels, workdir)
  end

  # ----- GROUPING TASKS BY DEPENDENCY LEVEL -----

  # Tasks with no deps = level 0
  # Tasks depending only on level 0 = level 1
  # etc.

  defp group_by_level(tasks, graph) do
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

  defp run_levels([], _workdir), do: {:ok, []}

  defp run_levels([level | rest], workdir) do
    IO.puts("\n#{IO.ANSI.faint()}── Level with #{length(level)} task(s) ──#{IO.ANSI.reset()}")

    # THIS IS THE PARALLEL BIT!
    # Task.async spawns a new process for each task
    # Task.await_many waits for all to complete

    async_tasks =
      level
      |> Enum.map(fn task ->
        Task.async(fn ->
          {task.name, run_single(task, workdir)}
        end)
      end)

    # Wait for all tasks in this level (5 minute timeout)
    results = Task.await_many(async_tasks, 300_000)

    # Check if any failed
    failed = Enum.find(results, fn {_name, status} -> status != :ok end)

    if failed do
      {name, {:error, _reason}} = failed
      IO.puts("#{IO.ANSI.red()}✗ #{name} failed, stopping#{IO.ANSI.reset()}")
      {:error, results}
    else
      # Continue to next level
      case run_levels(rest, workdir) do
        {:ok, rest_results} -> {:ok, results ++ rest_results}
        error -> error
      end
    end
  end

  # ----- RUNNING A SINGLE TASK -----

  defp run_single(%Sykli.Graph.Task{} = task, workdir) do
    # Check cache first
    case Sykli.Cache.check(task, workdir) do
      {:hit, key} ->
        # Restore outputs from cache
        case Sykli.Cache.restore(key, workdir) do
          :ok ->
            IO.puts(
              "#{IO.ANSI.yellow()}⊙ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(cached)#{IO.ANSI.reset()}"
            )

            maybe_github_status(task.name, "success")
            :ok

          {:error, reason} ->
            IO.puts(
              "#{IO.ANSI.yellow()}⚠ Cache restore failed for #{task.name}: #{inspect(reason)}#{IO.ANSI.reset()}"
            )

            run_and_cache(task, workdir, nil)
        end

      {:miss, cache_key} ->
        run_and_cache(task, workdir, cache_key)
    end
  end

  defp run_and_cache(%Sykli.Graph.Task{name: name, outputs: outputs} = task, workdir, cache_key) do
    # Build the actual command (docker run or direct)
    {run_cmd, display_cmd} = build_command(task, workdir)

    IO.puts("#{IO.ANSI.cyan()}▶ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{display_cmd}#{IO.ANSI.reset()}")

    # Post pending status to GitHub
    maybe_github_status(name, "pending")

    # Track execution time
    start_time = System.monotonic_time(:millisecond)

    # Run with streaming output
    case run_streaming(run_cmd, workdir) do
      {:ok, 0} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        IO.puts("#{IO.ANSI.green()}✓ #{name}#{IO.ANSI.reset()}")

        # Store in cache with outputs
        if cache_key do
          Sykli.Cache.store(cache_key, task, outputs || [], duration_ms, workdir)
        end

        maybe_github_status(name, "success")
        :ok

      {:ok, code} ->
        IO.puts("#{IO.ANSI.red()}✗ #{name} (exit #{code})#{IO.ANSI.reset()}")
        maybe_github_status(name, "failure")
        {:error, {:exit_code, code}}

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}✗ #{name} (error: #{inspect(reason)})#{IO.ANSI.reset()}")
        maybe_github_status(name, "failure")
        {:error, reason}
    end
  end

  # ----- COMMAND BUILDING -----

  # Build the command to run - either direct or via docker
  defp build_command(%Sykli.Graph.Task{container: nil, command: command}, _workdir) do
    # No container - run directly
    {command, command}
  end

  defp build_command(%Sykli.Graph.Task{} = task, workdir) do
    # Container task - build docker run command
    abs_workdir = Path.expand(workdir)

    docker_args = [
      "run",
      "--rm",
      # Don't use -it for non-interactive
    ]

    # Add volume mounts
    mount_args =
      (task.mounts || [])
      |> Enum.flat_map(fn mount ->
        case mount.type do
          "directory" ->
            # Bind mount: host path -> container path
            # Resource format: "src:." -> use "." as host path
            host_path = extract_host_path(mount.resource, abs_workdir)
            ["-v", "#{host_path}:#{mount.path}"]

          "cache" ->
            # Named volume for caches
            volume_name = "sykli-cache-#{mount.resource}"
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

    # Add environment variables
    env_args =
      (task.env || %{})
      |> Enum.flat_map(fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    # Build full command - quote the command for sh -c
    escaped_cmd = String.replace(task.command, "\"", "\\\"")
    all_args = docker_args ++ mount_args ++ workdir_args ++ env_args ++ [task.container, "sh", "-c", "\"#{escaped_cmd}\""]

    docker_cmd = Enum.join(["docker" | all_args], " ")

    # Display shows just the user's command
    display = "[#{task.container}] #{task.command}"

    {docker_cmd, display}
  end

  # Extract host path from resource ID
  # "src:." -> "."
  # "src:/path/to/dir" -> "/path/to/dir"
  defp extract_host_path(resource, abs_workdir) do
    case String.split(resource, ":", parts: 2) do
      ["src", path] ->
        # Relative paths should be relative to workdir
        if String.starts_with?(path, "/") do
          path
        else
          Path.join(abs_workdir, path)
        end

      _ ->
        # Fallback: use as-is
        abs_workdir
    end
  end

  # Run command with streaming output to console
  defp run_streaming(command, workdir) do
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
      stream_output(port)
    after
      Port.close(port)
    end
  end

  defp stream_output(port) do
    receive do
      {^port, {:data, data}} ->
        # Stream output with task prefix
        IO.write("  #{IO.ANSI.faint()}#{data}#{IO.ANSI.reset()}")
        stream_output(port)

      {^port, {:exit_status, status}} ->
        {:ok, status}
    after
      300_000 ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp maybe_github_status(task_name, state) do
    if Sykli.GitHub.enabled?() do
      Sykli.GitHub.update_status(task_name, state)
    end
  end
end
