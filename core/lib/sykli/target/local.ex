defmodule Sykli.Target.Local do
  @moduledoc """
  Local target - executes pipelines on the local machine.

  Uses Sykli.Error for structured error reporting.

  This is the default target for development and local CI runs.
  It composes with a Runtime to determine HOW commands execute:

  - Shell runtime: Direct execution (no containers)
  - Docker runtime: Container-based execution
  - Podman runtime: Rootless container execution (future)

  ## Architecture

      ┌─────────────────────────────────────────────────┐
      │              Local Target                       │
      │  (WHERE: local machine)                         │
      │                                                 │
      │  ┌─────────┐  ┌─────────┐  ┌─────────┐        │
      │  │  Shell  │  │ Docker  │  │ Podman  │  ...   │
      │  │ Runtime │  │ Runtime │  │ Runtime │        │
      │  └─────────┘  └─────────┘  └─────────┘        │
      │  (HOW: direct) (HOW: docker) (HOW: podman)    │
      └─────────────────────────────────────────────────┘

  ## State

  - `workdir`: Base working directory
  - `runtime`: Module implementing Runtime.Behaviour (Docker or Shell)

  ## Example

      # Setup with Docker runtime (default)
      {:ok, state} = Sykli.Target.Local.setup(workdir: "/tmp/build")

      # Setup with Shell runtime (no containers)
      {:ok, state} = Sykli.Target.Local.setup(
        workdir: "/tmp/build",
        runtime: Sykli.Runtime.Shell
      )

      # Run a task
      :ok = Sykli.Target.Local.run_task(task, state, [])

      # Cleanup
      :ok = Sykli.Target.Local.teardown(state)
  """

  @behaviour Sykli.Target.Behaviour

  defstruct [:workdir, :runtime]

  @default_runtime Sykli.Runtime.Docker

  # ─────────────────────────────────────────────────────────────────────────────
  # STATELESS CONVENIENCE (for RPC / Mesh)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Run a task without requiring external lifecycle management.

  This is a convenience function that handles setup, task execution, and teardown
  in a single call. Useful for RPC dispatch (e.g., Mesh distributed execution)
  where the caller doesn't want to manage state.

  ## Options

  Same as `setup/1`:
  - `:workdir` - Working directory (default: ".")
  - `:runtime` - Runtime module (default: Docker)

  ## Example

      # Single stateless call - no setup/teardown needed
      :ok = Target.Local.run_task_stateless(task, workdir: "/tmp/build")

  """
  def run_task_stateless(task, opts \\ []) do
    case setup(opts) do
      {:ok, state} ->
        try do
          run_task(task, state, opts)
        after
          teardown(state)
        end

      {:error, reason} ->
        {:error, {:setup_failed, reason}}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # IDENTITY
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def name, do: "local"

  @impl true
  def available? do
    # Check if at least one runtime is available
    case @default_runtime.available?() do
      {:ok, info} ->
        {:ok, %{runtime: @default_runtime.name(), info: info}}

      {:error, _} ->
        # Fall back to shell
        case Sykli.Runtime.Shell.available?() do
          {:ok, info} -> {:ok, %{runtime: "shell", info: info}}
          error -> error
        end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # LIFECYCLE
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def setup(opts) do
    workdir = Keyword.get(opts, :workdir, ".")
    runtime = Keyword.get(opts, :runtime, @default_runtime)

    # Verify runtime is available
    case runtime.available?() do
      {:ok, info} ->
        IO.puts(
          "#{IO.ANSI.faint()}Target: local (#{runtime.name()}: #{format_runtime_info(info)})#{IO.ANSI.reset()}"
        )

        {:ok, %__MODULE__{workdir: Path.expand(workdir), runtime: runtime}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def teardown(_state) do
    :ok
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SECRETS
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def resolve_secret(name, _state) do
    case System.get_env(name) do
      nil -> {:error, :not_found}
      "" -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VOLUMES
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def create_volume(name, _opts, state) do
    path = Path.join([state.workdir, ".sykli", "volumes", name])

    case File.mkdir_p(path) do
      :ok ->
        {:ok, %{id: name, host_path: path, reference: path}}

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  @impl true
  def artifact_path(task_name, artifact_name, workdir, _state) do
    Path.join([workdir, ".sykli", "artifacts", task_name, artifact_name])
  end

  @impl true
  def copy_artifact(source_path, dest_path, workdir, _state) do
    abs_source = Path.join(workdir, source_path) |> Path.expand()
    abs_dest = Path.join(workdir, dest_path) |> Path.expand()
    abs_workdir = Path.expand(workdir)

    cond do
      not path_within?(abs_source, abs_workdir) ->
        {:error, {:path_traversal, source_path}}

      not path_within?(abs_dest, abs_workdir) ->
        {:error, {:path_traversal, dest_path}}

      File.regular?(abs_source) ->
        copy_file(abs_source, abs_dest)

      File.dir?(abs_source) ->
        copy_directory(abs_source, abs_dest)

      true ->
        {:error, {:source_not_found, source_path}}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SERVICES
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def start_services(_task_name, [], _state), do: {:ok, {nil, [], nil}}

  def start_services(task_name, services, state) do
    runtime = state.runtime

    # Check if runtime supports services
    unless function_exported?(runtime, :create_network, 1) do
      {:error, {:runtime_no_services, runtime.name()}}
    else
      network_name = "sykli-#{sanitize_name(task_name)}-#{:rand.uniform(100_000)}"

      case runtime.create_network(network_name) do
        {:ok, _} ->
          IO.puts("  #{IO.ANSI.faint()}Created network #{network_name}#{IO.ANSI.reset()}")

          # Start each service
          container_ids = start_service_containers(runtime, network_name, services)

          # Give services a moment to start
          if length(services) > 0, do: Process.sleep(1000)

          {:ok, {network_name, container_ids, runtime}}

        {:error, reason} ->
          {:error, {:network_create_failed, reason}}
      end
    end
  end

  @impl true
  def stop_services({nil, [], _}, _state), do: :ok

  def stop_services({network_name, container_ids, runtime}, _state) do
    # Stop and remove containers
    Enum.each(container_ids, fn container_id ->
      runtime.stop_service(container_id)
    end)

    # Remove network
    if network_name do
      runtime.remove_network(network_name)
      IO.puts("  #{IO.ANSI.faint()}Removed network #{network_name}#{IO.ANSI.reset()}")
    end

    :ok
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # TASK EXECUTION
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def run_task(task, state, opts) do
    base_workdir = Keyword.get(opts, :workdir, state.workdir)
    network = Keyword.get(opts, :network)
    progress = Keyword.get(opts, :progress)
    timeout_ms = (task.timeout || 300) * 1000

    # For shell execution (no container), combine base workdir with task workdir.
    # For container execution, task.workdir is the container workdir (passed separately).
    workdir =
      if is_nil(task.container) and task.workdir do
        Path.join(base_workdir, task.workdir) |> Path.expand()
      else
        base_workdir
      end

    prefix = progress_prefix(progress)

    # Get timestamp
    {_, {h, m, s}} = :calendar.local_time()
    timestamp = :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> to_string()

    # Determine runtime and build execution params
    {runtime, image, mounts, display_cmd} = build_execution_params(task, workdir, state)

    IO.puts(
      "#{prefix}#{IO.ANSI.cyan()}▶ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{timestamp} #{display_cmd}#{IO.ANSI.reset()}"
    )

    start_time = System.monotonic_time(:millisecond)

    run_opts = [
      workdir: workdir,
      env: task.env || %{},
      timeout_ms: timeout_ms,
      network: network,
      container_workdir: task.workdir
    ]

    case runtime.run(task.command, image, mounts, run_opts) do
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
          Sykli.Error.task_failed(
            task.name,
            display_cmd,
            code,
            output,
            duration_ms: duration_ms
          )

        IO.puts(Sykli.Error.Formatter.format_simple(error))
        {:error, error}

      {:error, :timeout} ->
        timeout_ms = (task.timeout || 300) * 1000
        error = Sykli.Error.task_timeout(task.name, display_cmd, timeout_ms)
        IO.puts(Sykli.Error.Formatter.format_simple(error))
        {:error, error}

      {:error, reason} ->
        error =
          Sykli.Error.internal("task execution failed: #{inspect(reason)}")
          |> Sykli.Error.with_task(task.name)

        IO.puts(Sykli.Error.Formatter.format_simple(error))
        {:error, error}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # EXECUTION PARAMS
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_execution_params(%{container: nil, command: command}, _workdir, _state) do
    # No container specified - use shell runtime regardless of configured runtime
    {Sykli.Runtime.Shell, nil, [], command}
  end

  defp build_execution_params(task, workdir, state) do
    abs_workdir = Path.expand(workdir)
    mounts = build_mounts(task.mounts || [], abs_workdir)
    display = "[#{task.container}] #{task.command}"
    {state.runtime, task.container, mounts, display}
  end

  defp build_mounts(mounts, abs_workdir) do
    Enum.map(mounts, fn mount ->
      case mount.type do
        "directory" ->
          host_path = extract_host_path(mount.resource, abs_workdir)
          %{type: :directory, host_path: host_path, container_path: mount.path}

        "cache" ->
          # For caches, host_path is the cache key (used as volume name)
          %{type: :cache, host_path: mount.resource, container_path: mount.path}
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

  # ─────────────────────────────────────────────────────────────────────────────
  # SERVICE CONTAINERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp start_service_containers(runtime, network_name, services) do
    Enum.map(services, fn %Sykli.Graph.Service{image: image, name: name} ->
      container_name = "#{network_name}-#{name}"

      case runtime.start_service(container_name, image, network_name, []) do
        {:ok, container_id} ->
          IO.puts("  #{IO.ANSI.faint()}Started service #{name} (#{image})#{IO.ANSI.reset()}")
          container_id

        {:error, reason} ->
          IO.puts(
            "  #{IO.ANSI.red()}Failed to start service #{name}: #{inspect(reason)}#{IO.ANSI.reset()}"
          )

          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FILE OPERATIONS
  # ─────────────────────────────────────────────────────────────────────────────

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

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp sanitize_name(name) do
    String.replace(name, ~r/[^a-zA-Z0-9_-]/, "_")
  end

  # Securely check if path is within base directory (prevents path traversal)
  defp path_within?(path, base) do
    path == base or String.starts_with?(path, base <> "/")
  end

  defp progress_prefix(nil), do: ""

  defp progress_prefix({current, total}),
    do: "#{IO.ANSI.faint()}[#{current}/#{total}]#{IO.ANSI.reset()} "

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp format_runtime_info(%{version: version}), do: version
  defp format_runtime_info(%{shell: shell}), do: shell
  defp format_runtime_info(info), do: inspect(info)
end
