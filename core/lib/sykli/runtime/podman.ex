defmodule Sykli.Runtime.Podman do
  @moduledoc """
  Podman runtime — executes commands in Podman containers.

  Mirrors `Sykli.Runtime.Docker` but shells out to `podman` instead of
  `docker`. Rootless mode for v1 (the default for current Podman builds).
  Rootful operation is future work.

  ## Features

  - Container isolation via `podman run --rm`
  - Image-based execution
  - Volume mounts (directories and caches)
  - Network support for service communication
  - Automatic cleanup (--rm)

  ## Example

      {:ok, info} = Sykli.Runtime.Podman.available?()
      #=> {:ok, %{version: "podman version 4.7.0", path: "/usr/bin/podman"}}

      {:ok, 0, lines, output} = Sykli.Runtime.Podman.run(
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
  def name, do: "podman"

  @impl true
  def available? do
    case System.find_executable("podman") do
      nil ->
        {:error, :podman_not_found}

      podman_path ->
        case System.cmd(podman_path, ["--version"], stderr_to_stdout: true) do
          {version, 0} ->
            {:ok, %{version: String.trim(version), path: podman_path}}

          {error, _} ->
            {:error, {:podman_error, error}}
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

    podman_path = podman_executable()
    container_name = "sykli-#{:erlang.unique_integer([:positive])}"

    args = ["run", "--rm", "--name", container_name]
    args = if network, do: args ++ ["--network", network], else: args
    args = args ++ build_mount_args(mounts, Path.expand(workdir))
    args = if container_workdir, do: args ++ ["-w", container_workdir], else: args
    args = args ++ Enum.flat_map(env, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
    args = args ++ [image, "sh", "-c", command]

    port =
      Port.open(
        {:spawn_executable, podman_path},
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
    podman_path = podman_executable()

    case System.cmd(podman_path, ["network", "create", name], stderr_to_stdout: true) do
      {_output, 0} -> {:ok, name}
      {error, code} -> {:error, {:podman_command_failed, code, error}}
    end
  end

  @impl true
  def remove_network(network_id) do
    podman_path = podman_executable()
    System.cmd(podman_path, ["network", "rm", network_id], stderr_to_stdout: true)
    :ok
  end

  @impl true
  def start_service(name, image, network, _opts) do
    podman_path = podman_executable()

    case System.cmd(
           podman_path,
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
      {output, 0} -> {:ok, String.trim(output)}
      {error, code} -> {:error, {:podman_command_failed, code, error}}
    end
  end

  @impl true
  def stop_service(container_id) do
    podman_path = podman_executable()
    System.cmd(podman_path, ["rm", "-f", container_id], stderr_to_stdout: true)
    :ok
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_mount_args(mounts, abs_workdir) do
    Enum.flat_map(mounts, fn mount ->
      case mount.type do
        :directory ->
          abs_host = Path.expand(mount.host_path)

          if path_within?(abs_host, abs_workdir) do
            ["-v", "#{abs_host}:#{mount.container_path}"]
          else
            raise ArgumentError,
                  "Podman mount host path #{mount.host_path} escapes workdir #{abs_workdir}"
          end

        :cache ->
          volume_name = "sykli-cache-#{sanitize_name(mount.host_path)}"
          ["-v", "#{volume_name}:#{mount.container_path}"]

        _ ->
          []
      end
    end)
  end

  defp path_within?(path, base) do
    path == base or String.starts_with?(path, base <> "/")
  end

  defp podman_executable do
    System.find_executable("podman") || "/usr/bin/podman"
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
        kill_podman_container(container_name)
        kill_port_process(port)
        safe_port_close(port)
        {:error, :timeout}
    end
  end

  defp kill_podman_container(container_name) do
    podman_path = podman_executable()
    System.cmd(podman_path, ["kill", container_name], stderr_to_stdout: true)
  rescue
    _ -> :ok
  end

  defp kill_port_process(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        pid_str = Integer.to_string(os_pid)

        System.cmd("pkill", ["-TERM", "-P", pid_str], stderr_to_stdout: true)
        System.cmd("kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true)
        System.cmd("kill", ["-TERM", pid_str], stderr_to_stdout: true)

        Process.sleep(100)

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
