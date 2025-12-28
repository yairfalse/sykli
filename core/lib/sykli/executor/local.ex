defmodule Sykli.Executor.Local do
  @moduledoc """
  Local executor using Docker containers and shell commands.

  This is the default executor for development and local CI runs.
  Tasks with containers run via `docker run`, others run directly via shell.
  Artifacts are stored as files in the workdir.
  Secrets are read from environment variables.
  """

  @behaviour Sykli.Executor.Behaviour

  # ----- BEHAVIOUR CALLBACKS -----

  @impl true
  def name, do: "local"

  @impl true
  def available? do
    case System.find_executable("docker") do
      nil -> false
      _path -> true
    end
  end

  @impl true
  def resolve_secret(name) do
    case System.get_env(name) do
      nil -> {:error, :not_found}
      "" -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  @impl true
  def artifact_path(task_name, artifact_name, workdir) do
    # Artifacts stored in .sykli/artifacts/<task>/<name>
    Path.join([workdir, ".sykli", "artifacts", task_name, artifact_name])
  end

  @impl true
  def copy_artifact(source_path, dest_path, workdir) do
    abs_source = Path.join(workdir, source_path) |> Path.expand()
    abs_dest = Path.join(workdir, dest_path) |> Path.expand()
    abs_workdir = Path.expand(workdir)

    cond do
      not String.starts_with?(abs_source, abs_workdir) ->
        {:error, {:path_traversal, source_path}}

      not String.starts_with?(abs_dest, abs_workdir) ->
        {:error, {:path_traversal, dest_path}}

      File.regular?(abs_source) ->
        copy_file(abs_source, abs_dest)

      File.dir?(abs_source) ->
        copy_directory(abs_source, abs_dest)

      true ->
        {:error, {:source_not_found, source_path}}
    end
  end

  @impl true
  def start_services(_task_name, []), do: {:ok, {nil, []}}

  def start_services(task_name, services) do
    docker_path = docker_executable()
    network_name = "sykli-#{sanitize_name(task_name)}-#{:rand.uniform(100_000)}"

    # Create network
    case System.cmd(docker_path, ["network", "create", network_name], stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("  #{IO.ANSI.faint()}Created network #{network_name}#{IO.ANSI.reset()}")

        # Start each service
        container_ids = start_service_containers(docker_path, network_name, services)

        # Give services a moment to start
        if length(services) > 0, do: Process.sleep(1000)

        {:ok, {network_name, container_ids}}

      {error, _} ->
        {:error, {:network_create_failed, error}}
    end
  end

  @impl true
  def stop_services({nil, []}), do: :ok

  def stop_services({network_name, container_ids}) do
    docker_path = docker_executable()

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

  @impl true
  def run_job(task, opts) do
    pipeline_workdir = Keyword.get(opts, :workdir, ".")
    network = Keyword.get(opts, :network)
    progress = Keyword.get(opts, :progress)
    timeout = (task.timeout || 300) * 1000

    # For shell tasks, combine pipeline workdir with task workdir
    # For container tasks, task.workdir is for inside the container (-w flag), not host
    effective_workdir =
      if task.container == nil do
        resolve_workdir(pipeline_workdir, task.workdir)
      else
        pipeline_workdir
      end

    prefix = progress_prefix(progress)

    # Get timestamp
    {_, {h, m, s}} = :calendar.local_time()
    timestamp = :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> to_string()

    # Build command (pass pipeline workdir for container mounts)
    {cmd_type, cmd_args, display_cmd} = build_command(task, pipeline_workdir, network)

    IO.puts(
      "#{prefix}#{IO.ANSI.cyan()}▶ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{timestamp} #{display_cmd}#{IO.ANSI.reset()}"
    )

    start_time = System.monotonic_time(:millisecond)

    case run_streaming(cmd_type, cmd_args, effective_workdir, timeout) do
      {:ok, 0, lines, _output} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        lines_str = if lines > 0, do: " #{lines}L", else: ""

        IO.puts(
          "#{IO.ANSI.green()}✓ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{format_duration(duration_ms)}#{lines_str}#{IO.ANSI.reset()}"
        )

        :ok

      {:ok, code, _lines, output} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        error =
          Sykli.TaskError.new(
            task: task.name,
            command: display_cmd,
            exit_code: code,
            output: output,
            duration_ms: duration_ms
          )

        IO.puts(Sykli.TaskError.format(error))
        {:error, {:exit_code, code}}

      {:error, :timeout} ->
        IO.puts(
          "#{IO.ANSI.red()}✗ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(timeout after #{task.timeout}s)#{IO.ANSI.reset()}"
        )

        {:error, :timeout}

      {:error, reason} ->
        IO.puts(
          "#{IO.ANSI.red()}✗ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(error: #{inspect(reason)})#{IO.ANSI.reset()}"
        )

        {:error, reason}
    end
  end

  # ----- COMMAND BUILDING -----

  defp build_command(%{container: nil, command: command}, _workdir, _network) do
    {:shell, command, command}
  end

  defp build_command(task, workdir, network) do
    abs_workdir = Path.expand(workdir)

    docker_args = ["run", "--rm"]

    # Network args
    network_args = if network, do: ["--network", network], else: []

    # Mount args
    mount_args = build_mount_args(task.mounts || [], abs_workdir)

    # Workdir args
    workdir_args = if task.workdir, do: ["-w", task.workdir], else: []

    # Environment args
    env_args = Enum.flat_map(task.env || %{}, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    all_args =
      docker_args ++
        network_args ++
        mount_args ++
        workdir_args ++
        env_args ++
        [task.container, "sh", "-c", task.command]

    display = "[#{task.container}] #{task.command}"
    {:docker, all_args, display}
  end

  defp build_mount_args(mounts, abs_workdir) do
    Enum.flat_map(mounts, fn mount ->
      case mount.type do
        "directory" ->
          host_path = extract_host_path(mount.resource, abs_workdir)
          ["-v", "#{host_path}:#{mount.path}"]

        "cache" ->
          volume_name = "sykli-cache-#{sanitize_name(mount.resource)}"
          ["-v", "#{volume_name}:#{mount.path}"]

        _ ->
          []
      end
    end)
  end

  defp extract_host_path(resource, abs_workdir) do
    case String.split(resource, ":", parts: 2) do
      ["src", path] ->
        full_path =
          if String.starts_with?(path, "/"), do: path, else: Path.join(abs_workdir, path)

        Path.expand(full_path)

      _ ->
        abs_workdir
    end
  end

  # ----- COMMAND EXECUTION -----

  defp run_streaming(:shell, command, workdir, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [:binary, :exit_status, :stderr_to_stdout, args: ["-c", command], cd: workdir]
      )

    try do
      stream_output(port, timeout_ms)
    after
      safe_port_close(port)
    end
  end

  defp run_streaming(:docker, args, workdir, timeout_ms) do
    docker_path = docker_executable()

    port =
      Port.open(
        {:spawn_executable, docker_path},
        [:binary, :exit_status, :stderr_to_stdout, args: args, cd: workdir]
      )

    try do
      stream_output(port, timeout_ms)
    after
      safe_port_close(port)
    end
  end

  defp stream_output(port, timeout_ms), do: stream_output(port, timeout_ms, 0, [])

  defp stream_output(port, timeout_ms, line_count, output_acc) do
    receive do
      {^port, {:data, data}} ->
        IO.write("  #{IO.ANSI.faint()}#{data}#{IO.ANSI.reset()}")
        new_lines = data |> :binary.matches("\n") |> length()
        stream_output(port, timeout_ms, line_count + new_lines, [data | output_acc])

      {^port, {:exit_status, status}} ->
        full_output = output_acc |> Enum.reverse() |> Enum.join()
        output = String.slice(full_output, -min(String.length(full_output), 4000)..-1//1)
        {:ok, status, line_count, output}
    after
      timeout_ms ->
        safe_port_close(port)
        {:error, :timeout}
    end
  end

  defp safe_port_close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  # ----- SERVICE CONTAINERS -----

  defp start_service_containers(docker_path, network_name, services) do
    Enum.map(services, fn %Sykli.Graph.Service{image: image, name: name} ->
      container_name = "#{network_name}-#{name}"

      {output, 0} =
        System.cmd(
          docker_path,
          [
            "run",
            "-d",
            "--name",
            container_name,
            "--network",
            network_name,
            "--network-alias",
            name,
            image
          ],
          stderr_to_stdout: true
        )

      container_id = String.trim(output)
      IO.puts("  #{IO.ANSI.faint()}Started service #{name} (#{image})#{IO.ANSI.reset()}")
      container_id
    end)
  end

  # ----- FILE OPERATIONS -----

  defp copy_file(abs_source, abs_dest) do
    dest_dir = Path.dirname(abs_dest)

    with :ok <- File.mkdir_p(dest_dir),
         {:ok, _bytes} <- File.copy(abs_source, abs_dest) do
      # Preserve executable permissions
      case File.stat(abs_source) do
        {:ok, %{mode: mode}} -> File.chmod(abs_dest, mode)
        _ -> :ok
      end

      :ok
    else
      {:error, reason} -> {:error, {:copy_failed, reason}}
    end
  end

  defp copy_directory(abs_source, abs_dest) do
    with :ok <- File.mkdir_p(abs_dest),
         {:ok, _} <- File.cp_r(abs_source, abs_dest) do
      :ok
    else
      {:error, reason, _file} -> {:error, {:copy_failed, reason}}
      {:error, reason} -> {:error, {:copy_failed, reason}}
    end
  end

  # ----- HELPERS -----

  # Resolve effective workdir: combine pipeline workdir with task workdir
  defp resolve_workdir(pipeline_workdir, nil), do: pipeline_workdir
  defp resolve_workdir(pipeline_workdir, ""), do: pipeline_workdir

  defp resolve_workdir(pipeline_workdir, task_workdir) do
    Path.join(pipeline_workdir, task_workdir) |> Path.expand()
  end

  defp docker_executable do
    System.find_executable("docker") || "/usr/bin/docker"
  end

  defp sanitize_name(name) do
    String.replace(name, ~r/[^a-zA-Z0-9_-]/, "_")
  end

  defp progress_prefix(nil), do: ""

  defp progress_prefix({current, total}),
    do: "#{IO.ANSI.faint()}[#{current}/#{total}]#{IO.ANSI.reset()} "

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"
end
