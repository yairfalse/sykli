defmodule Sykli.Target.K8s do
  @moduledoc """
  Kubernetes target for running tasks as Jobs.

  This target runs tasks as Kubernetes Jobs with full control over:
  - Pod scheduling (node selectors, tolerations, affinity)
  - Resources (CPU, memory, GPU)
  - Security (service accounts, security contexts)
  - Storage (PVCs, ConfigMaps, Secrets)

  ## No CRDs, No Controllers

  Unlike Tekton/Argo, SYKLI doesn't use custom resources. Tasks run as
  standard Kubernetes Jobs:

  1. Build Job manifest from task spec + K8s options
  2. Create Job via kubectl/API
  3. Wait for completion
  4. Collect logs and exit code
  5. Delete Job

  ## Configuration

  The target can run:
  - **In-cluster**: Uses service account token (automatic in pods)
  - **Out-of-cluster**: Uses kubeconfig file

  ## State

  - `namespace`: Target namespace for Jobs
  - `kubeconfig`: Path to kubeconfig (nil for in-cluster)
  - `artifact_pvc`: PVC name for artifact storage

  ## Example

      {:ok, state} = Sykli.Target.K8s.setup(
        namespace: "sykli-jobs",
        kubeconfig: "~/.kube/config"
      )

      :ok = Sykli.Target.K8s.run_task(task, state, [])
  """

  @behaviour Sykli.Target.Behaviour

  alias Sykli.Target.K8sOptions

  defstruct [
    :namespace,
    :kubeconfig,
    :artifact_pvc,
    :in_cluster
  ]

  # ─────────────────────────────────────────────────────────────────────────────
  # IDENTITY
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def name, do: "k8s"

  @impl true
  def available? do
    cond do
      # Check for in-cluster config first
      in_cluster?() ->
        {:ok, %{mode: :in_cluster}}

      # Then check for kubeconfig
      kubeconfig = find_kubeconfig() ->
        case verify_kubeconfig(kubeconfig) do
          :ok -> {:ok, %{mode: :kubeconfig, path: kubeconfig}}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :no_kubeconfig}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # LIFECYCLE
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def setup(opts) do
    namespace = Keyword.get(opts, :namespace, default_namespace())
    _kubeconfig = Keyword.get(opts, :kubeconfig)

    case available?() do
      {:ok, %{mode: mode} = info} ->
        state = %__MODULE__{
          namespace: namespace,
          kubeconfig: if(mode == :kubeconfig, do: info.path, else: nil),
          in_cluster: mode == :in_cluster,
          artifact_pvc: Keyword.get(opts, :artifact_pvc, "sykli-artifacts")
        }

        mode_str = if state.in_cluster, do: "in-cluster", else: "kubeconfig"
        IO.puts("#{IO.ANSI.faint()}Target: k8s (#{mode_str}, namespace: #{namespace})#{IO.ANSI.reset()}")

        # Ensure namespace exists
        ensure_namespace(state)

        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def teardown(_state) do
    # Could cleanup completed Jobs here if desired
    :ok
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SECRETS
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def resolve_secret(name, _state) do
    # Try to read from K8s Secret
    # For now, fall back to environment variable
    # TODO: Implement actual K8s Secret reading
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
  def create_volume(name, opts, _state) do
    _size = Map.get(opts, :size, "1Gi")

    # TODO: Create PVC via kubectl/API
    # For now, return a reference that will be used in Job spec
    {:ok, %{
      id: name,
      host_path: nil,  # Not applicable for K8s
      reference: "pvc:#{name}"
    }}
  end

  @impl true
  def artifact_path(task_name, artifact_name, _workdir, _state) do
    # Artifacts stored in PVC at /artifacts/<task>/<name>
    Path.join(["/artifacts", task_name, artifact_name])
  end

  @impl true
  def copy_artifact(_source_path, _dest_path, _workdir, _state) do
    # In K8s, artifacts are on shared PVC
    # The init container will handle copying
    # TODO: Implement via kubectl cp or shared PVC
    :ok
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SERVICES
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def start_services(_task_name, [], _state), do: {:ok, nil}

  def start_services(task_name, services, _state) do
    # Services in K8s can be:
    # 1. Sidecar containers in the same Pod (simpler, same lifecycle)
    # 2. Separate Pods with Services (more isolated, but complex)
    #
    # We'll use sidecars for simplicity - they're added to the Job spec
    # and share the same network namespace
    {:ok, %{services: services, task_name: task_name}}
  end

  @impl true
  def stop_services(nil, _state), do: :ok

  def stop_services(_network_info, _state) do
    # Sidecars terminate with the Job - nothing to cleanup
    :ok
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # TASK EXECUTION
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def run_task(task, state, opts) do
    progress = Keyword.get(opts, :progress)
    prefix = progress_prefix(progress)

    # Get timestamp
    {_, {h, m, s}} = :calendar.local_time()
    timestamp = :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> to_string()

    job_name = generate_job_name(task.name)

    IO.puts("#{prefix}#{IO.ANSI.cyan()}▶ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{timestamp} [k8s:#{job_name}]#{IO.ANSI.reset()}")

    start_time = System.monotonic_time(:millisecond)

    # Build and apply Job
    case build_job_manifest(task, job_name, state, opts) do
      {:ok, manifest} ->
        case apply_job(manifest, state) do
          :ok ->
            # Wait for completion
            case wait_for_job(job_name, state, task.timeout || 300) do
              {:ok, :succeeded} ->
                duration_ms = System.monotonic_time(:millisecond) - start_time
                IO.puts("#{IO.ANSI.green()}✓ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{format_duration(duration_ms)}#{IO.ANSI.reset()}")
                cleanup_job(job_name, state)
                :ok

              {:ok, :failed} ->
                duration_ms = System.monotonic_time(:millisecond) - start_time
                logs = get_job_logs(job_name, state)
                IO.puts("#{IO.ANSI.red()}✗ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{format_duration(duration_ms)}#{IO.ANSI.reset()}")
                IO.puts("#{IO.ANSI.faint()}#{logs}#{IO.ANSI.reset()}")
                cleanup_job(job_name, state)
                {:error, :job_failed}

              {:error, :timeout} ->
                IO.puts("#{IO.ANSI.red()}✗ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(timeout)#{IO.ANSI.reset()}")
                cleanup_job(job_name, state)
                {:error, :timeout}

              {:error, reason} ->
                IO.puts("#{IO.ANSI.red()}✗ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(#{inspect(reason)})#{IO.ANSI.reset()}")
                cleanup_job(job_name, state)
                {:error, reason}
            end

          {:error, reason} ->
            IO.puts("#{IO.ANSI.red()}✗ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(failed to create job: #{inspect(reason)})#{IO.ANSI.reset()}")
            {:error, reason}
        end

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}✗ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(invalid manifest: #{inspect(reason)})#{IO.ANSI.reset()}")
        {:error, reason}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # JOB MANIFEST BUILDING
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Builds a Kubernetes Job manifest from task spec.

  The manifest includes:
  - Pod spec with container
  - Resource requests/limits
  - Volume mounts
  - Service sidecars
  - K8s-specific options (tolerations, affinity, etc.)
  """
  def build_job_manifest(task, job_name, state, opts) do
    k8s_opts = task.k8s || %K8sOptions{}
    namespace = k8s_opts.namespace || state.namespace
    services = Keyword.get(opts, :services, [])

    # Build container spec
    container = build_container_spec(task, k8s_opts)

    # Build sidecar containers for services
    sidecars = Enum.map(services, &build_sidecar_spec/1)

    # Build pod spec
    pod_spec = %{
      "restartPolicy" => "Never",
      "containers" => [container | sidecars]
    }

    # Add optional pod spec fields
    pod_spec = pod_spec
      |> maybe_add("nodeSelector", k8s_opts.node_selector)
      |> maybe_add("tolerations", build_tolerations(k8s_opts.tolerations))
      |> maybe_add("affinity", build_affinity(k8s_opts.affinity))
      |> maybe_add("serviceAccountName", k8s_opts.service_account)
      |> maybe_add("priorityClassName", k8s_opts.priority_class_name)
      |> maybe_add("hostNetwork", k8s_opts.host_network)
      |> maybe_add("dnsPolicy", k8s_opts.dns_policy)
      |> maybe_add("volumes", build_volumes(task, k8s_opts))

    # Build Job manifest
    manifest = %{
      "apiVersion" => "batch/v1",
      "kind" => "Job",
      "metadata" => %{
        "name" => job_name,
        "namespace" => namespace,
        "labels" => Map.merge(
          %{"sykli.io/task" => task.name},
          k8s_opts.labels || %{}
        ),
        "annotations" => k8s_opts.annotations || %{}
      },
      "spec" => %{
        "backoffLimit" => 0,  # No retries at Job level (SYKLI handles retries)
        "ttlSecondsAfterFinished" => 300,  # Auto-cleanup after 5 min
        "template" => %{
          "metadata" => %{
            "labels" => %{"sykli.io/task" => task.name}
          },
          "spec" => pod_spec
        }
      }
    }

    {:ok, manifest}
  end

  defp build_container_spec(task, k8s_opts) do
    container = %{
      "name" => "task",
      "image" => task.container || "alpine:latest",
      "command" => ["sh", "-c", task.command]
    }

    # Add workdir
    container = if task.workdir do
      Map.put(container, "workingDir", task.workdir)
    else
      container
    end

    # Add environment variables
    container = if task.env && map_size(task.env) > 0 do
      env_vars = Enum.map(task.env, fn {k, v} ->
        %{"name" => k, "value" => v}
      end)
      Map.put(container, "env", env_vars)
    else
      container
    end

    # Add resources
    container = if k8s_opts.resources || k8s_opts.gpu do
      resources = build_resources(k8s_opts)
      Map.put(container, "resources", resources)
    else
      container
    end

    # Add security context
    container = if k8s_opts.security_context do
      Map.put(container, "securityContext", build_security_context(k8s_opts.security_context))
    else
      container
    end

    # Add volume mounts
    container = if task.mounts && length(task.mounts) > 0 do
      mounts = Enum.map(task.mounts, fn m ->
        %{"name" => sanitize_name(m.resource), "mountPath" => m.path}
      end)
      Map.put(container, "volumeMounts", mounts)
    else
      container
    end

    container
  end

  defp build_sidecar_spec(%Sykli.Graph.Service{image: image, name: name}) do
    %{
      "name" => sanitize_name(name),
      "image" => image
    }
  end

  defp build_resources(k8s_opts) do
    resources = %{}

    # Resolve shorthand fields
    res = if k8s_opts.resources do
      K8sOptions.Resources.resolve(k8s_opts.resources)
    else
      %K8sOptions.Resources{}
    end

    # Build requests
    requests = %{}
    requests = if res.request_cpu, do: Map.put(requests, "cpu", res.request_cpu), else: requests
    requests = if res.request_memory, do: Map.put(requests, "memory", res.request_memory), else: requests

    # Build limits
    limits = %{}
    limits = if res.limit_cpu, do: Map.put(limits, "cpu", res.limit_cpu), else: limits
    limits = if res.limit_memory, do: Map.put(limits, "memory", res.limit_memory), else: limits

    # Add GPU
    limits = if k8s_opts.gpu && k8s_opts.gpu > 0 do
      Map.put(limits, "nvidia.com/gpu", to_string(k8s_opts.gpu))
    else
      limits
    end

    resources = if map_size(requests) > 0, do: Map.put(resources, "requests", requests), else: resources
    resources = if map_size(limits) > 0, do: Map.put(resources, "limits", limits), else: resources

    resources
  end

  defp build_tolerations(nil), do: nil
  defp build_tolerations(tolerations) do
    Enum.map(tolerations, fn t ->
      tol = %{"operator" => t.operator || "Equal"}
      tol = if t.key, do: Map.put(tol, "key", t.key), else: tol
      tol = if t.value, do: Map.put(tol, "value", t.value), else: tol
      tol = if t.effect, do: Map.put(tol, "effect", t.effect), else: tol
      tol
    end)
  end

  defp build_affinity(nil), do: nil
  defp build_affinity(affinity) do
    aff = %{}

    aff = if affinity.node_affinity do
      na = affinity.node_affinity
      node_aff = %{}

      node_aff = if na.required_labels && map_size(na.required_labels) > 0 do
        Map.put(node_aff, "requiredDuringSchedulingIgnoredDuringExecution", %{
          "nodeSelectorTerms" => [%{
            "matchExpressions" => Enum.map(na.required_labels, fn {k, v} ->
              %{"key" => k, "operator" => "In", "values" => [v]}
            end)
          }]
        })
      else
        node_aff
      end

      Map.put(aff, "nodeAffinity", node_aff)
    else
      aff
    end

    if map_size(aff) > 0, do: aff, else: nil
  end

  defp build_security_context(sc) do
    ctx = %{}
    ctx = if sc.run_as_user, do: Map.put(ctx, "runAsUser", sc.run_as_user), else: ctx
    ctx = if sc.run_as_group, do: Map.put(ctx, "runAsGroup", sc.run_as_group), else: ctx
    ctx = if sc.run_as_non_root, do: Map.put(ctx, "runAsNonRoot", sc.run_as_non_root), else: ctx
    ctx = if sc.privileged, do: Map.put(ctx, "privileged", sc.privileged), else: ctx
    ctx = if sc.read_only_root_filesystem, do: Map.put(ctx, "readOnlyRootFilesystem", sc.read_only_root_filesystem), else: ctx

    ctx = if sc.add_capabilities || sc.drop_capabilities do
      caps = %{}
      caps = if sc.add_capabilities, do: Map.put(caps, "add", sc.add_capabilities), else: caps
      caps = if sc.drop_capabilities, do: Map.put(caps, "drop", sc.drop_capabilities), else: caps
      Map.put(ctx, "capabilities", caps)
    else
      ctx
    end

    ctx
  end

  defp build_volumes(task, k8s_opts) do
    # Volumes from task mounts
    mount_volumes = (task.mounts || [])
      |> Enum.map(fn m ->
        case m.type do
          "cache" ->
            %{
              "name" => sanitize_name(m.resource),
              "emptyDir" => %{}
            }
          "directory" ->
            # For directories, we'd need a PVC or hostPath
            # For now, use emptyDir (loses data)
            %{
              "name" => sanitize_name(m.resource),
              "emptyDir" => %{}
            }
        end
      end)

    # Additional K8s volumes
    k8s_volumes = (k8s_opts.volumes || [])
      |> Enum.map(&build_k8s_volume/1)

    mount_volumes ++ k8s_volumes
  end

  defp build_k8s_volume(%K8sOptions.Volume{} = v) do
    vol = %{"name" => v.name}

    cond do
      v.config_map ->
        Map.put(vol, "configMap", %{"name" => v.config_map.name})
      v.secret ->
        Map.put(vol, "secret", %{"secretName" => v.secret.name})
      v.empty_dir ->
        ed = %{}
        ed = if v.empty_dir.medium, do: Map.put(ed, "medium", v.empty_dir.medium), else: ed
        ed = if v.empty_dir.size_limit, do: Map.put(ed, "sizeLimit", v.empty_dir.size_limit), else: ed
        Map.put(vol, "emptyDir", ed)
      v.host_path ->
        hp = %{"path" => v.host_path.path}
        hp = if v.host_path.type, do: Map.put(hp, "type", v.host_path.type), else: hp
        Map.put(vol, "hostPath", hp)
      v.pvc ->
        Map.put(vol, "persistentVolumeClaim", %{"claimName" => v.pvc.claim_name})
      true ->
        vol
    end
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, _key, value) when value == %{}, do: map
  defp maybe_add(map, _key, value) when value == [], do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  # ─────────────────────────────────────────────────────────────────────────────
  # KUBECTL OPERATIONS
  # ─────────────────────────────────────────────────────────────────────────────

  defp apply_job(manifest, state) do
    json = Jason.encode!(manifest)
    kubectl_path = System.find_executable("kubectl") || "kubectl"

    # Write manifest to temp file and apply from there
    # This avoids stdin piping issues with System.cmd (no :input option)
    tmp_path = Path.join(System.tmp_dir!(), "sykli-job-#{:erlang.unique_integer([:positive])}.json")

    try do
      File.write!(tmp_path, json)
      args = kubectl_args(state) ++ ["apply", "-f", tmp_path]

      case System.cmd(kubectl_path, args, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {error, _} -> {:error, error}
      end
    after
      File.rm(tmp_path)
    end
  end

  defp wait_for_job(job_name, state, timeout_seconds) do
    args = kubectl_args(state) ++ [
      "wait", "job/#{job_name}",
      "--for=condition=Complete",
      "--timeout=#{timeout_seconds}s"
    ]

    case System.cmd("kubectl", args, stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, :succeeded}

      {output, _} ->
        if String.contains?(output, "timed out") do
          {:error, :timeout}
        else
          # Check if job failed
          {:ok, get_job_status(job_name, state)}
        end
    end
  end

  defp get_job_status(job_name, state) do
    args = kubectl_args(state) ++ [
      "get", "job/#{job_name}",
      "-o", "jsonpath={.status.conditions[?(@.type==\"Failed\")].status}"
    ]

    case System.cmd("kubectl", args, stderr_to_stdout: true) do
      {"True" <> _, 0} -> :failed
      _ -> :unknown
    end
  end

  defp get_job_logs(job_name, state) do
    args = kubectl_args(state) ++ ["logs", "job/#{job_name}", "--tail=50"]

    case System.cmd("kubectl", args, stderr_to_stdout: true) do
      {logs, 0} -> logs
      {error, _} -> "Failed to get logs: #{error}"
    end
  end

  defp cleanup_job(job_name, state) do
    args = kubectl_args(state) ++ ["delete", "job/#{job_name}", "--ignore-not-found"]
    System.cmd("kubectl", args, stderr_to_stdout: true)
    :ok
  end

  defp ensure_namespace(state) do
    args = kubectl_args(state) ++ ["get", "namespace", state.namespace]

    case System.cmd("kubectl", args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        # Create namespace
        create_args = kubectl_args(state) ++ ["create", "namespace", state.namespace]
        System.cmd("kubectl", create_args, stderr_to_stdout: true)
        :ok
    end
  end

  defp kubectl_args(%{kubeconfig: nil}), do: []
  defp kubectl_args(%{kubeconfig: path}), do: ["--kubeconfig", path]

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp in_cluster? do
    File.exists?("/var/run/secrets/kubernetes.io/serviceaccount/token")
  end

  defp find_kubeconfig do
    cond do
      path = System.get_env("KUBECONFIG") ->
        if File.exists?(path), do: path, else: nil

      home = System.get_env("HOME") ->
        path = Path.join([home, ".kube", "config"])
        if File.exists?(path), do: path, else: nil

      true ->
        nil
    end
  end

  defp verify_kubeconfig(path) do
    case System.cmd("kubectl", ["--kubeconfig", path, "cluster-info"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, _} -> {:error, {:kubeconfig_invalid, error}}
    end
  end

  defp default_namespace do
    System.get_env("SYKLI_K8S_NAMESPACE") || "sykli"
  end

  defp generate_job_name(task_name) do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "sykli-#{sanitize_name(task_name)}-#{suffix}"
  end

  defp sanitize_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.slice(0, 50)
  end

  defp progress_prefix(nil), do: ""
  defp progress_prefix({current, total}), do: "#{IO.ANSI.faint()}[#{current}/#{total}]#{IO.ANSI.reset()} "

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"
end
