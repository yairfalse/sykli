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
    # Check condition first
    if should_run?(task) do
      # Validate required secrets are present
      case validate_secrets(task) do
        :ok ->
          run_task_with_cache(task, workdir)

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

  defp run_task_with_cache(%Sykli.Graph.Task{} = task, workdir) do
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

  defp run_and_cache(%Sykli.Graph.Task{name: name, outputs: outputs, services: services} = task, workdir, cache_key) do
    # Start services if any
    {network, service_containers} = start_services(name, services || [])

    try do
      # Build the actual command (docker run or direct)
      cmd_tuple = build_command(task, workdir, network)
      display_cmd = elem(cmd_tuple, 2)

      IO.puts("#{IO.ANSI.cyan()}▶ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{display_cmd}#{IO.ANSI.reset()}")

      # Post pending status to GitHub
      maybe_github_status(name, "pending")

      # Track execution time
      start_time = System.monotonic_time(:millisecond)

      # Run with streaming output
      case run_streaming(cmd_tuple, workdir) do
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
  defp run_streaming({:shell, command, _display}, workdir) do
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
      stream_output(port)
    after
      safe_port_close(port)
    end
  end

  defp run_streaming({:docker, args, _display}, workdir) do
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
      stream_output(port)
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

  # Evaluate a condition expression against context
  # Supports: branch == 'main', tag != '', event == 'push'
  defp evaluate_condition(condition, context) do
    cond do
      # branch == 'value'
      Regex.match?(~r/^branch\s*==\s*'([^']*)'$/, condition) ->
        [_, value] = Regex.run(~r/^branch\s*==\s*'([^']*)'$/, condition)
        context["branch"] == value

      # branch != 'value'
      Regex.match?(~r/^branch\s*!=\s*'([^']*)'$/, condition) ->
        [_, value] = Regex.run(~r/^branch\s*!=\s*'([^']*)'$/, condition)
        context["branch"] != value

      # tag == 'value' (for specific tag)
      Regex.match?(~r/^tag\s*==\s*'([^']*)'$/, condition) ->
        [_, value] = Regex.run(~r/^tag\s*==\s*'([^']*)'$/, condition)
        context["tag"] == value

      # tag != '' (any tag)
      Regex.match?(~r/^tag\s*!=\s*''$/, condition) ->
        context["tag"] != nil && context["tag"] != false && context["tag"] != ""

      # event == 'value'
      Regex.match?(~r/^event\s*==\s*'([^']*)'$/, condition) ->
        [_, value] = Regex.run(~r/^event\s*==\s*'([^']*)'$/, condition)
        context["event"] == value

      # ci == true
      condition == "ci == true" ->
        context["ci"] == true

      # Unknown condition - default to true (run the task)
      true ->
        IO.puts(
          "#{IO.ANSI.yellow()}⚠ Unknown condition format: #{condition}, running task#{IO.ANSI.reset()}"
        )

        true
    end
  end
end
