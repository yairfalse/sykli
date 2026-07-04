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
  - `runtime`: Module implementing `Sykli.Runtime.Behaviour`, used for tasks
    that declare a container image. Resolved via `Sykli.Runtime.Resolver`.
  - `containerless_runtime`: Module implementing `Sykli.Runtime.Behaviour`,
    used for tasks with `container: nil`. Resolved via
    `Sykli.Runtime.Resolver.resolve_containerless/1`. Defaults to
    `Sykli.Runtime.Shell`.

  ## Example

      # Setup with the resolved default runtime (see `Sykli.Runtime.Resolver`).
      {:ok, state} = Sykli.Target.Local.setup(workdir: "/tmp/build")

      # Setup with an explicit runtime override.
      {:ok, state} = Sykli.Target.Local.setup(
        workdir: "/tmp/build",
        runtime: runtime_module
      )

      # Run a task
      :ok = Sykli.Target.Local.run_task(task, state, [])

      # Cleanup
      :ok = Sykli.Target.Local.teardown(state)
  """

  @behaviour Sykli.Target.Behaviour

  alias Sykli.EvidenceRequirement.Result, as: EvidenceResult
  alias Sykli.SuccessCriteria.Result

  defstruct [:workdir, :runtime, :containerless_runtime, :timeout_ms]

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
  - `:runtime` - Runtime module (default: resolved via `Sykli.Runtime.Resolver`)

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
    # Delegate runtime selection to the Resolver (priority chain + fallback).
    runtime = Sykli.Runtime.Resolver.resolve([])

    case runtime.available?() do
      {:ok, info} -> {:ok, %{runtime: runtime.name(), info: info}}
      {:error, _} = err -> err
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # LIFECYCLE
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def setup(opts) do
    workdir = Keyword.get(opts, :workdir, ".")
    runtime = Sykli.Runtime.Resolver.resolve(opts)
    containerless_runtime = Sykli.Runtime.Resolver.resolve_containerless(opts)

    with {:ok, _info} <- runtime.available?(),
         {:ok, _containerless_info} <- containerless_runtime.available?() do
      timeout_ms = Keyword.get(opts, :timeout)

      {:ok,
       %__MODULE__{
         workdir: Path.expand(workdir),
         runtime: runtime,
         containerless_runtime: containerless_runtime,
         timeout_ms: timeout_ms
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def teardown(_state) do
    :ok
  end

  def network_isolation?(task, state) do
    runtime = runtime_for_task(task, state)
    function_exported?(runtime, :network_isolation?, 0) and runtime.network_isolation?()
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

      true ->
        # Internal structured reasons; executor/target callers format them at the boundary.
        case File.lstat(abs_source) do
          {:ok, %{type: :regular}} -> copy_file(abs_source, abs_dest)
          {:ok, %{type: :directory}} -> copy_directory(abs_source, abs_dest)
          {:ok, %{type: :symlink}} -> {:error, {:symlink_not_allowed, source_path}}
          {:ok, _} -> {:error, {:source_not_regular, source_path}}
          {:error, _} -> {:error, {:source_not_found, source_path}}
        end
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
      network_name = Sykli.Target.NetworkName.deterministic(task_name, services, state.workdir)

      case runtime.create_network(network_name) do
        {:ok, _} ->
          case start_service_containers(runtime, network_name, services) do
            {:ok, container_ids} ->
              # Give services a moment to start
              if length(services) > 0, do: Process.sleep(1000)

              {:ok, {network_name, container_ids, runtime}}

            {:error, reason, started_container_ids} ->
              Enum.each(started_container_ids, &runtime.stop_service/1)
              runtime.remove_network(network_name)
              {:error, reason}
          end

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
    # Per-task timeout: task.timeout (seconds) > global --timeout > 5 min default
    base_timeout_ms =
      cond do
        task.timeout -> task.timeout * 1000
        state.timeout_ms -> state.timeout_ms
        true -> 300_000
      end

    mandate_timeout_ms = Keyword.get(opts, :mandate_timeout_ms)
    timeout_ms = min_timeout(base_timeout_ms, mandate_timeout_ms)
    mandate_timeout? = is_integer(mandate_timeout_ms) and timeout_ms == mandate_timeout_ms

    # For shell execution (no container), combine base workdir with task workdir.
    # For container execution, task.workdir is the container workdir (passed separately).
    workdir =
      if is_nil(task.container) and task.workdir do
        Path.join(base_workdir, task.workdir) |> Path.expand()
      else
        base_workdir
      end

    # Presentation (live progress, success/failure lines) is the renderer's job,
    # not the target's. Target.Local executes and returns structured results only;
    # Sykli.CLI.Renderer renders them. See #237.
    {runtime, image, mounts, display_cmd} = build_execution_params(task, workdir, state)

    start_time = System.monotonic_time(:millisecond)

    run_opts = [
      workdir: workdir,
      env: task.env || %{},
      timeout_ms: timeout_ms,
      network: network,
      container_workdir: task.workdir
    ]

    case runtime.run(task.command, image, mounts, run_opts) do
      {:ok, 0, _lines, output} ->
        {:ok, output || ""}

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

        {:error, error}

      {:error, :timeout} ->
        if mandate_timeout? do
          {:error, {:mandate_budget_exceeded, "wall_clock_ms", timeout_ms, mandate_timeout_ms}}
        else
          {:error, Sykli.Error.task_timeout(task.name, display_cmd, timeout_ms)}
        end

      {:error, reason} ->
        error =
          Sykli.Error.internal("task execution failed: #{inspect(reason)}")
          |> Sykli.Error.with_task(task.name)

        {:error, error}
    end
  end

  defp min_timeout(timeout_ms, nil), do: timeout_ms
  defp min_timeout(timeout_ms, mandate_timeout_ms), do: min(timeout_ms, mandate_timeout_ms)

  @impl true
  def evaluate_success_criteria(task, criteria, state, opts) do
    base_workdir = Keyword.get(opts, :workdir, state.workdir)
    target_workdir = resolved_task_workdir(task, base_workdir)
    command_exit_code = Keyword.get(opts, :command_exit_code, 0)

    results =
      criteria
      |> Enum.with_index()
      |> Enum.map(fn {criterion, index} ->
        evaluate_success_criterion(criterion, index, task, target_workdir, command_exit_code)
      end)

    case Sykli.SuccessCriteria.failures(results) do
      [] ->
        {:ok, results}

      failures ->
        error =
          if Enum.any?(failures, &(&1.status == :unsupported)) do
            Sykli.Error.unsupported_success_criteria_for_target(
              task.name,
              name(),
              failures,
              command: task.command
            )
          else
            Sykli.Error.success_criteria_failed(
              task.name,
              failures,
              command: task.command
            )
          end

        {:error, error, results}
    end
  end

  @impl true
  def evaluate_evidence_required(task, requirements, state, opts) do
    base_workdir = Keyword.get(opts, :workdir, state.workdir)
    target_workdir = resolved_task_workdir(task, base_workdir)

    results =
      requirements
      |> Enum.with_index()
      |> Enum.map(fn {requirement, index} ->
        evaluate_evidence_requirement(requirement, index, task, target_workdir)
      end)

    case Sykli.EvidenceRequirement.failures(results) do
      [] ->
        {:ok, results}

      failures ->
        error =
          if Enum.any?(failures, &(&1.status == :unsupported)) do
            Sykli.Error.unsupported_evidence_requirement_for_target(
              task.name,
              name(),
              failures,
              command: task.command
            )
          else
            Sykli.Error.missing_evidence(
              task.name,
              failures,
              command: task.command
            )
          end

        {:error, error, results}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # EXECUTION PARAMS
  # ─────────────────────────────────────────────────────────────────────────────

  defp runtime_for_task(%{container: nil}, state), do: state.containerless_runtime
  defp runtime_for_task(_task, state), do: state.runtime

  defp build_execution_params(%{container: nil, command: command}, _workdir, state) do
    # No container image — run via the containerless runtime (composed at
    # setup/1 time, defaults to Sykli.Runtime.Shell via Resolver).
    {state.containerless_runtime, nil, [], command}
  end

  defp build_execution_params(task, workdir, state) do
    abs_workdir = Path.expand(workdir)
    mounts = build_mounts(task.mounts || [], abs_workdir)
    display = "[#{task.container}] #{task.command}"
    {state.runtime, task.container, mounts, display}
  end

  defp resolved_task_workdir(%{container: nil, workdir: task_workdir}, base_workdir)
       when is_binary(task_workdir) and task_workdir != "" do
    Path.join(base_workdir, task_workdir) |> Path.expand()
  end

  defp resolved_task_workdir(_task, base_workdir), do: Path.expand(base_workdir)

  defp evaluate_success_criterion(
         %{"type" => "exit_code", "equals" => expected},
         index,
         _task,
         _workdir,
         actual
       ) do
    if actual == expected do
      criterion_passed(index, "exit_code", "exit code matched #{expected}", %{
        expected: expected,
        actual: actual
      })
    else
      criterion_failed(index, "exit_code", "expected exit code #{expected}, got #{actual}", %{
        expected: expected,
        actual: actual
      })
    end
  end

  defp evaluate_success_criterion(
         %{"type" => type, "path" => path},
         index,
         %{container: nil},
         workdir,
         _actual
       )
       when type in ["file_exists", "file_non_empty"] do
    with {:ok, resolved_path} <- resolve_criterion_path(path, workdir),
         {:ok, stat} <- stat_regular_file(resolved_path, path) do
      evaluate_file_criterion(type, index, path, resolved_path, stat)
    else
      {:error, message, evidence} ->
        criterion_failed(index, type, message, evidence)
    end
  end

  defp evaluate_success_criterion(
         %{"type" => type, "path" => path},
         index,
         %{container: container},
         _workdir,
         _actual
       )
       when type in ["file_exists", "file_non_empty"] and is_binary(container) do
    criterion_unsupported(
      index,
      type,
      "local target cannot evaluate #{type} inside container runtime #{inspect(container)}",
      %{path: path, container: container}
    )
  end

  defp evaluate_success_criterion(%{"type" => type} = criterion, index, _task, _workdir, _actual) do
    criterion_unsupported(
      index,
      type,
      "unrecognized success_criteria type #{inspect(type)}",
      criterion
    )
  end

  defp evaluate_evidence_requirement(
         %{"type" => "file", "ref_pattern" => path, "name" => name} = requirement,
         index,
         %{container: nil},
         workdir
       ) do
    predicate = Map.get(requirement, "predicate", "exists")
    required = Map.get(requirement, "required", true)

    with {:ok, resolved_path} <- resolve_criterion_path(path, workdir),
         {:ok, stat} <- stat_regular_file(resolved_path, path) do
      evaluate_file_evidence_requirement(
        index,
        name,
        required,
        predicate,
        path,
        resolved_path,
        stat
      )
    else
      {:error, message, evidence} ->
        evidence_missing(index, "file", name, required, message, evidence)
    end
  end

  defp evaluate_evidence_requirement(
         %{"type" => "file", "ref_pattern" => path, "name" => name} = requirement,
         index,
         %{container: container},
         _workdir
       )
       when is_binary(container) do
    evidence_unsupported(
      index,
      "file",
      name,
      Map.get(requirement, "required", true),
      "local target cannot evaluate file evidence inside container runtime #{inspect(container)}",
      %{path: path, container: container}
    )
  end

  defp evaluate_evidence_requirement(
         %{"type" => type, "name" => name} = requirement,
         index,
         _task,
         _workdir
       ) do
    evidence_unsupported(
      index,
      type,
      name,
      Map.get(requirement, "required", true),
      "local target does not yet evaluate evidence_required type #{inspect(type)}",
      requirement
    )
  end

  defp evaluate_file_evidence_requirement(
         index,
         name,
         required,
         "exists",
         path,
         resolved_path,
         _stat
       ) do
    evidence_satisfied(
      index,
      "file",
      name,
      required,
      "file evidence exists",
      file_ref(path, resolved_path)
    )
  end

  defp evaluate_file_evidence_requirement(
         index,
         name,
         required,
         "non_empty",
         path,
         resolved_path,
         %{
           size: size
         }
       ) do
    if size > 0 do
      evidence_satisfied(
        index,
        "file",
        name,
        required,
        "file evidence is non-empty",
        Map.put(file_ref(path, resolved_path), "size", size)
      )
    else
      evidence_missing(index, "file", name, required, "file evidence is empty", %{
        path: path,
        resolved_path: resolved_path,
        size: size
      })
    end
  end

  defp file_ref(path, resolved_path) do
    %{
      "type" => "local_ref",
      "uri" => "file://#{resolved_path}",
      "summary" => "local file evidence: #{path}",
      "visibility" => "local"
    }
  end

  defp resolve_criterion_path(path, workdir) do
    cond do
      Path.type(path) == :absolute ->
        {:error, "path must be relative to task workdir", %{path: path}}

      true ->
        resolved = Path.expand(Path.join(workdir, path))

        if path_within?(resolved, Path.expand(workdir)) do
          {:ok, resolved}
        else
          {:error, "path escapes task workdir", %{path: path}}
        end
    end
  end

  defp stat_regular_file(resolved_path, path) do
    case File.lstat(resolved_path) do
      {:ok, %{type: :regular} = stat} ->
        {:ok, stat}

      {:ok, %{type: :symlink}} ->
        {:error, "symlinks are not supported for declared check paths", %{path: path}}

      {:ok, %{type: type}} ->
        {:error, "path is not a regular file", %{path: path, file_type: type}}

      {:error, reason} ->
        {:error, "file not found", %{path: path, reason: reason}}
    end
  end

  defp evaluate_file_criterion("file_exists", index, path, resolved_path, _stat) do
    criterion_passed(index, "file_exists", "file exists", %{
      path: path,
      resolved_path: resolved_path
    })
  end

  defp evaluate_file_criterion("file_non_empty", index, path, resolved_path, %{size: size}) do
    if size > 0 do
      criterion_passed(index, "file_non_empty", "file is non-empty", %{
        path: path,
        resolved_path: resolved_path,
        size: size
      })
    else
      criterion_failed(index, "file_non_empty", "file is empty", %{
        path: path,
        resolved_path: resolved_path,
        size: size
      })
    end
  end

  defp criterion_passed(index, type, message, evidence) do
    %Result{
      index: index,
      type: type,
      status: :passed,
      message: message,
      evidence: evidence,
      target: name()
    }
  end

  defp criterion_failed(index, type, message, evidence) do
    %Result{
      index: index,
      type: type,
      status: :failed,
      message: message,
      evidence: evidence,
      target: name()
    }
  end

  defp criterion_unsupported(index, type, message, evidence) do
    %Result{
      index: index,
      type: type,
      status: :unsupported,
      message: message,
      evidence: evidence,
      target: name()
    }
  end

  defp evidence_satisfied(index, type, evidence_name, required, message, evidence_ref) do
    %EvidenceResult{
      index: index,
      type: type,
      name: evidence_name,
      status: :satisfied,
      message: message,
      required: required,
      evidence_ref: evidence_ref,
      target: name()
    }
  end

  defp evidence_missing(index, type, evidence_name, required, message, evidence_ref) do
    %EvidenceResult{
      index: index,
      type: type,
      name: evidence_name,
      status: :missing,
      message: message,
      required: required,
      evidence_ref: evidence_ref,
      target: name()
    }
  end

  defp evidence_unsupported(index, type, evidence_name, required, message, evidence_ref) do
    %EvidenceResult{
      index: index,
      type: type,
      name: evidence_name,
      status: :unsupported,
      message: message,
      required: required,
      evidence_ref: evidence_ref,
      target: name()
    }
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
    resolved =
      case String.split(resource, ":", parts: 2) do
        ["src", path] ->
          full_path =
            if String.starts_with?(path, "/"), do: path, else: Path.join(abs_workdir, path)

          Path.expand(full_path)

        _ ->
          abs_workdir
      end

    # Block paths outside workdir to prevent host filesystem escape via mounts.
    # Use trailing slash to prevent prefix tricks (e.g., /tmp/workdir_evil matching /tmp/workdir)
    if resolved == abs_workdir or String.starts_with?(resolved, abs_workdir <> "/") do
      resolved
    else
      abs_workdir
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SERVICE CONTAINERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp start_service_containers(runtime, network_name, services) do
    result =
      Enum.reduce_while(services, [], fn %Sykli.Graph.Service{image: image, name: name},
                                         started_ids ->
        container_name = "#{network_name}-#{name}"

        case runtime.start_service(container_name, image, network_name, []) do
          {:ok, container_id} ->
            {:cont, [container_id | started_ids]}

          {:error, reason} ->
            {:halt, {:error, {:service_start_failed, name, reason}, Enum.reverse(started_ids)}}
        end
      end)

    case result do
      {:error, _reason, _started_ids} = error -> error
      started_ids -> {:ok, Enum.reverse(started_ids)}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FILE OPERATIONS
  # ─────────────────────────────────────────────────────────────────────────────

  defp copy_file(abs_source, abs_dest) do
    dest_dir = Path.dirname(abs_dest)

    with :ok <- File.mkdir_p(dest_dir),
         {:ok, _bytes} <- File.copy(abs_source, abs_dest) do
      # Preserve executable permissions without following a replaced symlink.
      case File.lstat(abs_source) do
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

  # Securely check if path is within base directory (prevents path traversal)
  defp path_within?(path, base) do
    path == base or String.starts_with?(path, base <> "/")
  end
end
