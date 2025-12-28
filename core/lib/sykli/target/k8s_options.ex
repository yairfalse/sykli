defmodule Sykli.Target.K8sOptions do
  @moduledoc """
  Kubernetes-specific task options.

  These options are only applied when running with a K8s target.
  They mirror the Go SDK's `K8sTaskOptions` struct for portable pipelines.

  ## Example (Go SDK)

      s.Task("train-model").
          Container("pytorch:latest").
          Run("python train.py").
          K8s(sykli.K8sTaskOptions{
              GPU: 4,
              Resources: sykli.K8sResources{Memory: "32Gi"},
              NodeSelector: map[string]string{"accelerator": "nvidia-a100"},
          })

  ## Usage

  When a task has K8s options and runs on the K8s target:

  1. Options are read from the task spec
  2. K8s executor builds a Job manifest
  3. Pod spec includes scheduling, resources, security settings
  4. Job runs to completion

  When running on Local target, K8s options are ignored.
  """

  # ─────────────────────────────────────────────────────────────────────────────
  # MAIN OPTIONS STRUCT
  # ─────────────────────────────────────────────────────────────────────────────

  defstruct [
    # Pod Scheduling
    # %{"disk" => "ssd", "zone" => "us-west-2a"}
    :node_selector,
    # [%Toleration{}]
    :tolerations,
    # %Affinity{}
    :affinity,
    # "high-priority"
    :priority_class_name,

    # Resources
    # %Resources{}
    :resources,
    # integer (nvidia.com/gpu)
    :gpu,

    # Security
    # "sykli-runner"
    :service_account,
    # %SecurityContext{}
    :security_context,

    # Networking
    # boolean
    :host_network,
    # "ClusterFirst"
    :dns_policy,

    # Storage
    # [%Volume{}]
    :volumes,

    # Metadata
    # %{"app" => "sykli"}
    :labels,
    # %{"prometheus.io/scrape" => "true"}
    :annotations,
    # "ci-jobs" (override default)
    :namespace
  ]

  @type t :: %__MODULE__{
          node_selector: map() | nil,
          tolerations: [Toleration.t()] | nil,
          affinity: Affinity.t() | nil,
          priority_class_name: String.t() | nil,
          resources: Resources.t() | nil,
          gpu: integer() | nil,
          service_account: String.t() | nil,
          security_context: SecurityContext.t() | nil,
          host_network: boolean() | nil,
          dns_policy: String.t() | nil,
          volumes: [Volume.t()] | nil,
          labels: map() | nil,
          annotations: map() | nil,
          namespace: String.t() | nil
        }

  # ─────────────────────────────────────────────────────────────────────────────
  # RESOURCES
  # ─────────────────────────────────────────────────────────────────────────────

  defmodule Resources do
    @moduledoc "CPU/memory requests and limits"

    defstruct [
      # "500m", "2"
      :request_cpu,
      # "512Mi", "4Gi"
      :request_memory,
      # "2", "4"
      :limit_cpu,
      # "4Gi", "16Gi"
      :limit_memory,
      # Shorthand: sets both request and limit
      # "2" -> request=2, limit=2
      :cpu,
      # "4Gi" -> request=4Gi, limit=4Gi
      :memory
    ]

    @type t :: %__MODULE__{
            request_cpu: String.t() | nil,
            request_memory: String.t() | nil,
            limit_cpu: String.t() | nil,
            limit_memory: String.t() | nil,
            cpu: String.t() | nil,
            memory: String.t() | nil
          }

    @doc "Resolves shorthand fields to explicit request/limit"
    def resolve(%__MODULE__{} = r) do
      %__MODULE__{
        request_cpu: r.request_cpu || r.cpu,
        request_memory: r.request_memory || r.memory,
        limit_cpu: r.limit_cpu || r.cpu,
        limit_memory: r.limit_memory || r.memory
      }
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # TOLERATIONS
  # ─────────────────────────────────────────────────────────────────────────────

  defmodule Toleration do
    @moduledoc "Allows scheduling on tainted nodes"

    defstruct [:key, :operator, :value, :effect]

    @type t :: %__MODULE__{
            key: String.t() | nil,
            # "Exists" | "Equal"
            operator: String.t(),
            value: String.t() | nil,
            # "NoSchedule" | "PreferNoSchedule" | "NoExecute"
            effect: String.t() | nil
          }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # AFFINITY
  # ─────────────────────────────────────────────────────────────────────────────

  defmodule Affinity do
    @moduledoc "Node and pod affinity rules"

    defstruct [:node_affinity, :pod_affinity, :pod_anti_affinity]

    @type t :: %__MODULE__{
            node_affinity: NodeAffinity.t() | nil,
            pod_affinity: PodAffinity.t() | nil,
            pod_anti_affinity: PodAffinity.t() | nil
          }
  end

  defmodule NodeAffinity do
    @moduledoc "Node selection rules"

    defstruct [:required_labels, :preferred_labels]

    @type t :: %__MODULE__{
            required_labels: map() | nil,
            preferred_labels: map() | nil
          }
  end

  defmodule PodAffinity do
    @moduledoc "Pod co-location rules"

    defstruct [:required_labels, :topology_key]

    @type t :: %__MODULE__{
            required_labels: map() | nil,
            topology_key: String.t() | nil
          }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SECURITY CONTEXT
  # ─────────────────────────────────────────────────────────────────────────────

  defmodule SecurityContext do
    @moduledoc "Container security settings"

    defstruct [
      :run_as_user,
      :run_as_group,
      :run_as_non_root,
      :privileged,
      :read_only_root_filesystem,
      :add_capabilities,
      :drop_capabilities
    ]

    @type t :: %__MODULE__{
            run_as_user: integer() | nil,
            run_as_group: integer() | nil,
            run_as_non_root: boolean() | nil,
            privileged: boolean() | nil,
            read_only_root_filesystem: boolean() | nil,
            add_capabilities: [String.t()] | nil,
            drop_capabilities: [String.t()] | nil
          }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VOLUMES
  # ─────────────────────────────────────────────────────────────────────────────

  defmodule Volume do
    @moduledoc "Additional volume mounts (beyond artifacts)"

    defstruct [:name, :mount_path, :config_map, :secret, :empty_dir, :host_path, :pvc]

    @type t :: %__MODULE__{
            name: String.t(),
            mount_path: String.t(),
            config_map: ConfigMapVolume.t() | nil,
            secret: SecretVolume.t() | nil,
            empty_dir: EmptyDirVolume.t() | nil,
            host_path: HostPathVolume.t() | nil,
            pvc: PVCVolume.t() | nil
          }
  end

  defmodule ConfigMapVolume do
    @moduledoc "Mount a ConfigMap"
    defstruct [:name]
    @type t :: %__MODULE__{name: String.t()}
  end

  defmodule SecretVolume do
    @moduledoc "Mount a Secret"
    defstruct [:name]
    @type t :: %__MODULE__{name: String.t()}
  end

  defmodule EmptyDirVolume do
    @moduledoc "Ephemeral volume"
    defstruct [:medium, :size_limit]

    @type t :: %__MODULE__{
            # "" (disk) or "Memory" (tmpfs)
            medium: String.t() | nil,
            size_limit: String.t() | nil
          }
  end

  defmodule HostPathVolume do
    @moduledoc "Mount a host path (use with caution)"
    defstruct [:path, :type]

    @type t :: %__MODULE__{
            path: String.t(),
            # "DirectoryOrCreate", "FileOrCreate", etc.
            type: String.t() | nil
          }
  end

  defmodule PVCVolume do
    @moduledoc "Mount an existing PVC"
    defstruct [:claim_name]
    @type t :: %__MODULE__{claim_name: String.t()}
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # PARSING
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Parses K8s options from JSON map (from SDK emission).

  Returns nil if map is nil or empty.
  """
  def parse(nil), do: nil
  def parse(map) when map == %{}, do: nil

  def parse(map) when is_map(map) do
    %__MODULE__{
      node_selector: map["node_selector"],
      tolerations: parse_tolerations(map["tolerations"]),
      affinity: parse_affinity(map["affinity"]),
      priority_class_name: map["priority_class_name"],
      resources: parse_resources(map["resources"]),
      gpu: map["gpu"],
      service_account: map["service_account"],
      security_context: parse_security_context(map["security_context"]),
      host_network: map["host_network"],
      dns_policy: map["dns_policy"],
      volumes: parse_volumes(map["volumes"]),
      labels: map["labels"],
      annotations: map["annotations"],
      namespace: map["namespace"]
    }
  end

  defp parse_tolerations(nil), do: nil

  defp parse_tolerations(list) when is_list(list) do
    Enum.map(list, fn t ->
      %Toleration{
        key: t["key"],
        operator: t["operator"] || "Equal",
        value: t["value"],
        effect: t["effect"]
      }
    end)
  end

  defp parse_affinity(nil), do: nil

  defp parse_affinity(map) do
    %Affinity{
      node_affinity: parse_node_affinity(map["node_affinity"]),
      pod_affinity: parse_pod_affinity(map["pod_affinity"]),
      pod_anti_affinity: parse_pod_affinity(map["pod_anti_affinity"])
    }
  end

  defp parse_node_affinity(nil), do: nil

  defp parse_node_affinity(map) do
    %NodeAffinity{
      required_labels: map["required_labels"],
      preferred_labels: map["preferred_labels"]
    }
  end

  defp parse_pod_affinity(nil), do: nil

  defp parse_pod_affinity(map) do
    %PodAffinity{
      required_labels: map["required_labels"],
      topology_key: map["topology_key"]
    }
  end

  defp parse_resources(nil), do: nil

  defp parse_resources(map) do
    %Resources{
      request_cpu: map["request_cpu"],
      request_memory: map["request_memory"],
      limit_cpu: map["limit_cpu"],
      limit_memory: map["limit_memory"],
      cpu: map["cpu"],
      memory: map["memory"]
    }
  end

  defp parse_security_context(nil), do: nil

  defp parse_security_context(map) do
    %SecurityContext{
      run_as_user: map["run_as_user"],
      run_as_group: map["run_as_group"],
      run_as_non_root: map["run_as_non_root"],
      privileged: map["privileged"],
      read_only_root_filesystem: map["read_only_root_filesystem"],
      add_capabilities: map["add_capabilities"],
      drop_capabilities: map["drop_capabilities"]
    }
  end

  defp parse_volumes(nil), do: nil

  defp parse_volumes(list) when is_list(list) do
    Enum.map(list, fn v ->
      %Volume{
        name: v["name"],
        mount_path: v["mount_path"],
        config_map: parse_config_map(v["config_map"]),
        secret: parse_secret_volume(v["secret"]),
        empty_dir: parse_empty_dir(v["empty_dir"]),
        host_path: parse_host_path(v["host_path"]),
        pvc: parse_pvc(v["pvc"])
      }
    end)
  end

  defp parse_config_map(nil), do: nil
  defp parse_config_map(map), do: %ConfigMapVolume{name: map["name"]}

  defp parse_secret_volume(nil), do: nil
  defp parse_secret_volume(map), do: %SecretVolume{name: map["name"]}

  defp parse_empty_dir(nil), do: nil

  defp parse_empty_dir(map) do
    %EmptyDirVolume{medium: map["medium"], size_limit: map["size_limit"]}
  end

  defp parse_host_path(nil), do: nil

  defp parse_host_path(map) do
    %HostPathVolume{path: map["path"], type: map["type"]}
  end

  defp parse_pvc(nil), do: nil
  defp parse_pvc(map), do: %PVCVolume{claim_name: map["claim_name"]}

  # ─────────────────────────────────────────────────────────────────────────────
  # MERGING
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Merges pipeline defaults with task-specific options.

  Task options override defaults. For maps (labels, annotations, node_selector),
  values are merged with task values winning.

  ## Example

      iex> defaults = %K8sOptions{namespace: "ci-jobs", resources: %Resources{memory: "2Gi"}}
      iex> task_opts = %K8sOptions{resources: %Resources{memory: "32Gi"}}
      iex> K8sOptions.merge(defaults, task_opts)
      %K8sOptions{namespace: "ci-jobs", resources: %Resources{memory: "32Gi"}}

  """
  def merge(nil, nil), do: nil
  def merge(defaults, nil), do: defaults
  def merge(nil, task_opts), do: task_opts

  def merge(%__MODULE__{} = defaults, %__MODULE__{} = task_opts) do
    %__MODULE__{
      # Scalars: task wins if not nil
      namespace: task_opts.namespace || defaults.namespace,
      priority_class_name: task_opts.priority_class_name || defaults.priority_class_name,
      service_account: task_opts.service_account || defaults.service_account,
      dns_policy: task_opts.dns_policy || defaults.dns_policy,
      gpu: task_opts.gpu || defaults.gpu,
      host_network:
        if(is_nil(task_opts.host_network), do: defaults.host_network, else: task_opts.host_network),

      # Resources: merge field by field
      resources: merge_resources(defaults.resources, task_opts.resources),

      # Maps: merge with task values winning
      node_selector: merge_maps(defaults.node_selector, task_opts.node_selector),
      labels: merge_maps(defaults.labels, task_opts.labels),
      annotations: merge_maps(defaults.annotations, task_opts.annotations),

      # Lists/structs: task replaces if not nil
      tolerations: task_opts.tolerations || defaults.tolerations,
      volumes: task_opts.volumes || defaults.volumes,
      affinity: task_opts.affinity || defaults.affinity,
      security_context: task_opts.security_context || defaults.security_context
    }
  end

  defp merge_resources(nil, nil), do: nil
  defp merge_resources(defaults, nil), do: defaults
  defp merge_resources(nil, task), do: task

  defp merge_resources(%Resources{} = defaults, %Resources{} = task) do
    %Resources{
      request_cpu: task.request_cpu || defaults.request_cpu,
      request_memory: task.request_memory || defaults.request_memory,
      limit_cpu: task.limit_cpu || defaults.limit_cpu,
      limit_memory: task.limit_memory || defaults.limit_memory,
      cpu: task.cpu || defaults.cpu,
      memory: task.memory || defaults.memory
    }
  end

  defp merge_maps(nil, nil), do: nil
  defp merge_maps(defaults, nil), do: defaults
  defp merge_maps(nil, task), do: task
  defp merge_maps(defaults, task), do: Map.merge(defaults, task)

  @doc """
  Returns true if the options struct has no meaningful values set.
  """
  def empty?(nil), do: true

  def empty?(%__MODULE__{} = opts) do
    is_nil(opts.namespace) and
      is_nil(opts.priority_class_name) and
      is_nil(opts.service_account) and
      is_nil(opts.dns_policy) and
      is_nil(opts.gpu) and
      (is_nil(opts.host_network) or opts.host_network == false) and
      (is_nil(opts.resources) or resources_empty?(opts.resources)) and
      (is_nil(opts.node_selector) or opts.node_selector == %{}) and
      (is_nil(opts.labels) or opts.labels == %{}) and
      (is_nil(opts.annotations) or opts.annotations == %{}) and
      is_nil(opts.tolerations) and
      is_nil(opts.volumes) and
      is_nil(opts.affinity) and
      is_nil(opts.security_context)
  end

  defp resources_empty?(%Resources{} = r) do
    is_nil(r.request_cpu) and
      is_nil(r.request_memory) and
      is_nil(r.limit_cpu) and
      is_nil(r.limit_memory) and
      is_nil(r.cpu) and
      is_nil(r.memory)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VALIDATION
  # ─────────────────────────────────────────────────────────────────────────────

  # K8s resource quantity patterns
  # Memory: Ki, Mi, Gi, Ti, Pi, Ei (binary) or k, M, G, T, P, E (decimal) or plain number
  @memory_pattern ~r/^[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$/
  # CPU: cores (integer/decimal) or millicores (suffixed with 'm')
  @cpu_pattern ~r/^[0-9]+(\.[0-9]+)?m?$/
  # Valid toleration operators
  @valid_operators ["Exists", "Equal"]
  # Valid toleration effects
  @valid_effects ["NoSchedule", "PreferNoSchedule", "NoExecute"]
  # Valid DNS policies
  @valid_dns_policies ["ClusterFirst", "ClusterFirstWithHostNet", "Default", "None"]

  @doc """
  Validates K8s options and returns a list of errors.

  Returns `{:ok, opts}` if valid, or `{:error, errors}` with a list of error tuples.

  ## Error Format

  Each error is a tuple: `{field, value, message}`

  ## Validation Rules

  - Memory format: Ki/Mi/Gi/Ti (e.g., '512Mi', '4Gi')
  - CPU format: cores or millicores (e.g., '500m', '0.5', '2')
  - Toleration operators: Exists, Equal
  - Toleration effects: NoSchedule, PreferNoSchedule, NoExecute
  - DNS policy: ClusterFirst, ClusterFirstWithHostNet, Default, None
  - Volume mount paths: must be absolute (start with /)

  ## Example

      iex> K8sOptions.validate(%K8sOptions{resources: %Resources{memory: "32gb"}})
      {:error, [{"resources.memory", "32gb", "invalid memory format, use Ki/Mi/Gi/Ti (e.g., '512Mi', '4Gi') (did you mean 'Gi'?)"}]}

  """
  def validate(nil), do: {:ok, nil}

  def validate(%__MODULE__{} = opts) do
    errors =
      []
      |> validate_resources(opts.resources)
      |> validate_tolerations(opts.tolerations)
      |> validate_dns_policy(opts.dns_policy)
      |> validate_volumes(opts.volumes)
      |> Enum.reverse()

    case errors do
      [] -> {:ok, opts}
      errs -> {:error, errs}
    end
  end

  defp validate_resources(errors, nil), do: errors

  defp validate_resources(errors, %Resources{} = r) do
    errors
    |> validate_memory("resources.memory", r.memory)
    |> validate_memory("resources.request_memory", r.request_memory)
    |> validate_memory("resources.limit_memory", r.limit_memory)
    |> validate_cpu("resources.cpu", r.cpu)
    |> validate_cpu("resources.request_cpu", r.request_cpu)
    |> validate_cpu("resources.limit_cpu", r.limit_cpu)
  end

  defp validate_memory(errors, _field, nil), do: errors

  defp validate_memory(errors, field, value) do
    if Regex.match?(@memory_pattern, value) do
      errors
    else
      suggestion = memory_suggestion(value)

      message = "invalid memory format, use Ki/Mi/Gi/Ti (e.g., '512Mi', '4Gi')" <> suggestion

      [{field, value, message} | errors]
    end
  end

  defp memory_suggestion(value) do
    lower = String.downcase(value)

    cond do
      String.ends_with?(lower, "gb") -> " (did you mean 'Gi'?)"
      String.ends_with?(lower, "mb") -> " (did you mean 'Mi'?)"
      String.ends_with?(lower, "kb") -> " (did you mean 'Ki'?)"
      true -> ""
    end
  end

  defp validate_cpu(errors, _field, nil), do: errors

  defp validate_cpu(errors, field, value) do
    if Regex.match?(@cpu_pattern, value) do
      errors
    else
      message = "invalid CPU format, use cores or millicores (e.g., '500m', '0.5', '2')"
      [{field, value, message} | errors]
    end
  end

  defp validate_tolerations(errors, nil), do: errors

  defp validate_tolerations(errors, tolerations) when is_list(tolerations) do
    tolerations
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {t, i}, acc ->
      acc
      |> validate_toleration_operator(i, t)
      |> validate_toleration_effect(i, t)
    end)
  end

  defp validate_toleration_operator(errors, i, %Toleration{operator: op})
       when is_binary(op) and op != "" and op not in @valid_operators do
    field = "tolerations[#{i}].operator"
    message = "must be 'Exists' or 'Equal'"
    [{field, op, message} | errors]
  end

  defp validate_toleration_operator(errors, _i, _t), do: errors

  defp validate_toleration_effect(errors, i, %Toleration{effect: effect})
       when is_binary(effect) and effect != "" and effect not in @valid_effects do
    field = "tolerations[#{i}].effect"
    message = "must be 'NoSchedule', 'PreferNoSchedule', or 'NoExecute'"
    [{field, effect, message} | errors]
  end

  defp validate_toleration_effect(errors, _i, _t), do: errors

  defp validate_dns_policy(errors, nil), do: errors

  defp validate_dns_policy(errors, policy) when policy in @valid_dns_policies, do: errors

  defp validate_dns_policy(errors, policy) do
    message = "must be one of: ClusterFirst, ClusterFirstWithHostNet, Default, None"
    [{"dns_policy", policy, message} | errors]
  end

  defp validate_volumes(errors, nil), do: errors

  defp validate_volumes(errors, volumes) when is_list(volumes) do
    volumes
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {v, i}, acc ->
      acc
      |> validate_volume_name(i, v)
      |> validate_volume_mount_path(i, v)
    end)
  end

  defp validate_volume_name(errors, i, %Volume{name: name})
       when is_nil(name) or name == "" do
    [{"volumes[#{i}].name", "", "volume name is required"} | errors]
  end

  defp validate_volume_name(errors, _i, _v), do: errors

  defp validate_volume_mount_path(errors, i, %Volume{mount_path: path})
       when is_nil(path) or path == "" do
    [{"volumes[#{i}].mount_path", "", "mount path is required"} | errors]
  end

  defp validate_volume_mount_path(errors, _i, %Volume{mount_path: "/" <> _}), do: errors

  defp validate_volume_mount_path(errors, i, %Volume{mount_path: path}) when is_binary(path) do
    [{"volumes[#{i}].mount_path", path, "mount path must be absolute (start with /)"} | errors]
  end

  defp validate_volume_mount_path(errors, _i, _v), do: errors

  @doc """
  Validates and returns error message for display.

  Returns `nil` if valid, or a formatted error message string.
  """
  def validate!(opts) do
    case validate(opts) do
      {:ok, _} ->
        nil

      {:error, [{field, value, message} | _]} ->
        "k8s.#{field}: #{message} (got #{inspect(value)})"
    end
  end
end
