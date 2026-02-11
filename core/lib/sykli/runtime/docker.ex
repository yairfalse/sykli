defmodule Sykli.Runtime.Docker do
  @moduledoc """
  Docker runtime - executes commands in Docker containers.

  This runtime provides container isolation using Docker. Each command
  runs in a fresh container with specified image, mounts, and environment.

  ## Features

  - Container isolation
  - Image-based execution
  - Volume mounts (directories and caches)
  - Network support for service communication
  - Automatic cleanup (--rm)

  ## Example

      {:ok, info} = Sykli.Runtime.Docker.available?()
      #=> {:ok, %{version: "Docker version 24.0.7..."}}

      {:ok, 0, lines, output} = Sykli.Runtime.Docker.run(
        "go build ./...",
        "golang:1.21",
        [%{type: :directory, host_path: "/src", container_path: "/app"}],
        workdir: "/app",
        timeout_ms: 300_000
      )
  """

  @behaviour Sykli.Runtime.Behaviour

  # ─────────────────────────────────────────────────────────────────────────────
  # IDENTITY
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def name, do: "docker"

  @impl true
  def available? do
    case System.find_executable("docker") do
      nil ->
        {:error, :docker_not_found}

      docker_path ->
        case System.cmd(docker_path, ["--version"], stderr_to_stdout: true) do
          {version, 0} ->
            {:ok, %{version: String.trim(version), path: docker_path}}

          {error, _} ->
            {:error, {:docker_error, error}}
        end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # EXECUTION
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def run(command, image, mounts, opts) do
    workdir = Keyword.get(opts, :workdir, ".")
    timeout_ms = Keyword.get(opts, :timeout_ms, 300_000)
    env = Keyword.get(opts, :env, %{})
    network = Keyword.get(opts, :network)
    container_workdir = Keyword.get(opts, :container_workdir)

    docker_path = docker_executable()
    container_name = "sykli-#{:erlang.unique_integer([:positive])}"

    args = ["run", "--rm", "--name", container_name]

    # Network
    args = if network, do: args ++ ["--network", network], else: args

    # Mounts
    args = args ++ build_mount_args(mounts)

    # Working directory inside container
    args = if container_workdir, do: args ++ ["-w", container_workdir], else: args

    # Environment variables
    args = args ++ Enum.flat_map(env, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    # Image and command
    args = args ++ [image, "sh", "-c", command]

    port =
      Port.open(
        {:spawn_executable, docker_path},
        [:binary, :exit_status, :stderr_to_stdout, args: args, cd: workdir]
      )

    try do
      stream_output(port, timeout_ms, container_name)
    after
      safe_port_close(port)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SERVICES
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def create_network(name) do
    docker_path = docker_executable()

    case System.cmd(docker_path, ["network", "create", name], stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, name}

      {error, _} ->
        {:error, {:network_create_failed, error}}
    end
  end

  @impl true
  def remove_network(network_id) do
    docker_path = docker_executable()
    System.cmd(docker_path, ["network", "rm", network_id], stderr_to_stdout: true)
    :ok
  end

  @impl true
  def start_service(name, image, network, _opts) do
    docker_path = docker_executable()

    case System.cmd(
           docker_path,
           [
             "run",
             "-d",
             "--name",
             name,
             "--network",
             network,
             "--network-alias",
             name,
             image
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {error, _} ->
        {:error, {:service_start_failed, error}}
    end
  end

  @impl true
  def stop_service(container_id) do
    docker_path = docker_executable()
    System.cmd(docker_path, ["rm", "-f", container_id], stderr_to_stdout: true)
    :ok
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_mount_args(mounts) do
    Enum.flat_map(mounts, fn mount ->
      case mount.type do
        :directory ->
          ["-v", "#{mount.host_path}:#{mount.container_path}"]

        :cache ->
          # Caches use named volumes
          volume_name = "sykli-cache-#{sanitize_name(mount.host_path)}"
          ["-v", "#{volume_name}:#{mount.container_path}"]

        _ ->
          []
      end
    end)
  end

  defp docker_executable do
    System.find_executable("docker") || "/usr/bin/docker"
  end

  defp sanitize_name(name) do
    String.replace(name, ~r/[^a-zA-Z0-9_-]/, "_")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # STREAMING
  # ─────────────────────────────────────────────────────────────────────────────

  defp stream_output(port, timeout_ms, container_name),
    do: stream_output(port, timeout_ms, container_name, 0, [])

  defp stream_output(port, timeout_ms, container_name, line_count, output_acc) do
    receive do
      {^port, {:data, data}} ->
        IO.write("  #{IO.ANSI.faint()}#{data}#{IO.ANSI.reset()}")
        new_lines = data |> :binary.matches("\n") |> length()

        stream_output(port, timeout_ms, container_name, line_count + new_lines, [
          data | output_acc
        ])

      {^port, {:exit_status, status}} ->
        full_output = output_acc |> Enum.reverse() |> Enum.join()
        output = String.slice(full_output, -min(String.length(full_output), 4000)..-1//1)
        {:ok, status, line_count, output}
    after
      timeout_ms ->
        kill_docker_container(container_name)
        kill_port_process(port)
        safe_port_close(port)
        {:error, :timeout}
    end
  end

  defp kill_docker_container(container_name) do
    docker_path = docker_executable()
    System.cmd(docker_path, ["kill", container_name], stderr_to_stdout: true)
  rescue
    _ -> :ok
  end

  defp kill_port_process(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        pid_str = Integer.to_string(os_pid)

        # Kill children first (works on Linux where process group kill may not)
        System.cmd("pkill", ["-TERM", "-P", pid_str], stderr_to_stdout: true)
        # Kill the process group (works on macOS)
        System.cmd("kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true)
        # Kill the process itself
        System.cmd("kill", ["-TERM", pid_str], stderr_to_stdout: true)

        Process.sleep(100)

        # Force kill anything still alive
        System.cmd("pkill", ["-9", "-P", pid_str], stderr_to_stdout: true)
        System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true)
        System.cmd("kill", ["-9", pid_str], stderr_to_stdout: true)

      nil ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp safe_port_close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end
end
