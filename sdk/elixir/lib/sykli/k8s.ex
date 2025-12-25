defmodule Sykli.K8s do
  @moduledoc """
  Kubernetes-specific configuration for tasks.

  Provides strongly-typed K8s options with validation and helpful error messages.

  ## Example

      alias Sykli.K8s

      task "build" do
        run "cargo build"
        k8s K8s.options()
             |> K8s.memory("4Gi")
             |> K8s.cpu("2")
             |> K8s.gpu(1)
      end

  ## Validation

  All K8s options are validated when the pipeline is emitted:

      # This will fail with a helpful message:
      k8s K8s.options() |> K8s.memory("4gb")
      # => k8s.resources.memory: invalid format '4gb' (did you mean 'Gi'?)

  """

  require Logger

  # =============================================================================
  # OPTIONS STRUCT
  # =============================================================================

  defstruct namespace: nil,
            node_selector: %{},
            tolerations: [],
            affinity: nil,
            priority_class: nil,
            resources: %{},
            gpu: nil,
            service_account: nil,
            security_context: nil,
            host_network: false,
            dns_policy: nil,
            volumes: [],
            labels: %{},
            annotations: %{}

  @type t :: %__MODULE__{
          namespace: String.t() | nil,
          node_selector: %{String.t() => String.t()},
          tolerations: [toleration()],
          affinity: affinity() | nil,
          priority_class: String.t() | nil,
          resources: resources(),
          gpu: non_neg_integer() | nil,
          service_account: String.t() | nil,
          security_context: security_context() | nil,
          host_network: boolean(),
          dns_policy: String.t() | nil,
          volumes: [volume()],
          labels: %{String.t() => String.t()},
          annotations: %{String.t() => String.t()}
        }

  @type resources :: %{
          optional(:cpu) => String.t(),
          optional(:memory) => String.t(),
          optional(:request_cpu) => String.t(),
          optional(:request_memory) => String.t(),
          optional(:limit_cpu) => String.t(),
          optional(:limit_memory) => String.t()
        }

  @type toleration :: %{
          key: String.t(),
          operator: String.t(),
          value: String.t() | nil,
          effect: String.t()
        }

  @type affinity :: %{
          optional(:node_affinity) => node_affinity(),
          optional(:pod_affinity) => pod_affinity(),
          optional(:pod_anti_affinity) => pod_affinity()
        }

  @type node_affinity :: %{
          optional(:required_labels) => %{String.t() => String.t()},
          optional(:preferred_labels) => %{String.t() => String.t()}
        }

  @type pod_affinity :: %{
          required_labels: %{String.t() => String.t()},
          topology_key: String.t()
        }

  @type security_context :: %{
          optional(:run_as_user) => integer(),
          optional(:run_as_group) => integer(),
          optional(:run_as_non_root) => boolean(),
          optional(:privileged) => boolean(),
          optional(:read_only_root_fs) => boolean(),
          optional(:add_capabilities) => [String.t()],
          optional(:drop_capabilities) => [String.t()]
        }

  @type volume :: %{
          name: String.t(),
          mount_path: String.t(),
          config_map: String.t() | nil,
          secret: String.t() | nil,
          empty_dir: empty_dir() | nil,
          host_path: host_path() | nil,
          pvc: String.t() | nil
        }

  @type empty_dir :: %{
          optional(:medium) => String.t(),
          optional(:size_limit) => String.t()
        }

  @type host_path :: %{
          path: String.t(),
          type: String.t() | nil
        }

  # =============================================================================
  # VALIDATION ERROR
  # =============================================================================

  defmodule ValidationError do
    @moduledoc "K8s validation error with field, value, and message."
    defexception [:field, :value, :message]

    @impl true
    def message(%{field: field, value: value, message: msg}) do
      "k8s.#{field}: #{msg} (got #{inspect(value)})"
    end
  end

  # =============================================================================
  # BUILDER API
  # =============================================================================

  @doc "Creates a new K8s options struct."
  @spec options() :: t()
  def options, do: %__MODULE__{}

  @doc "Sets the Kubernetes namespace."
  @spec namespace(t(), String.t()) :: t()
  def namespace(opts, ns) when is_binary(ns), do: %{opts | namespace: ns}

  @doc """
  Sets memory resource (both request and limit).

  Use K8s binary units: Ki, Mi, Gi, Ti.

  ## Examples

      K8s.options() |> K8s.memory("4Gi")
      K8s.options() |> K8s.memory("512Mi")
  """
  @spec memory(t(), String.t()) :: t()
  def memory(opts, value) when is_binary(value) do
    resources = Map.put(opts.resources, :memory, value)
    %{opts | resources: resources}
  end

  @doc """
  Sets CPU resource (both request and limit).

  Use cores (e.g., "2") or millicores (e.g., "500m").

  ## Examples

      K8s.options() |> K8s.cpu("2")
      K8s.options() |> K8s.cpu("500m")
  """
  @spec cpu(t(), String.t()) :: t()
  def cpu(opts, value) when is_binary(value) do
    resources = Map.put(opts.resources, :cpu, value)
    %{opts | resources: resources}
  end

  @doc "Sets the memory request (distinct from limit)."
  @spec request_memory(t(), String.t()) :: t()
  def request_memory(opts, value) when is_binary(value) do
    resources = Map.put(opts.resources, :request_memory, value)
    %{opts | resources: resources}
  end

  @doc "Sets the memory limit (distinct from request)."
  @spec limit_memory(t(), String.t()) :: t()
  def limit_memory(opts, value) when is_binary(value) do
    resources = Map.put(opts.resources, :limit_memory, value)
    %{opts | resources: resources}
  end

  @doc "Sets the CPU request (distinct from limit)."
  @spec request_cpu(t(), String.t()) :: t()
  def request_cpu(opts, value) when is_binary(value) do
    resources = Map.put(opts.resources, :request_cpu, value)
    %{opts | resources: resources}
  end

  @doc "Sets the CPU limit (distinct from request)."
  @spec limit_cpu(t(), String.t()) :: t()
  def limit_cpu(opts, value) when is_binary(value) do
    resources = Map.put(opts.resources, :limit_cpu, value)
    %{opts | resources: resources}
  end

  @doc "Requests NVIDIA GPUs."
  @spec gpu(t(), non_neg_integer()) :: t()
  def gpu(opts, count) when is_integer(count) and count >= 0 do
    %{opts | gpu: count}
  end

  @doc "Sets a node selector label."
  @spec node_selector(t(), String.t(), String.t()) :: t()
  def node_selector(opts, key, value) do
    %{opts | node_selector: Map.put(opts.node_selector, key, value)}
  end

  @doc "Adds a toleration."
  @spec toleration(t(), String.t(), String.t(), String.t(), String.t() | nil) :: t()
  def toleration(opts, key, operator, effect, value \\ nil) do
    tol = %{key: key, operator: operator, effect: effect, value: value}
    %{opts | tolerations: opts.tolerations ++ [tol]}
  end

  @doc "Sets the priority class."
  @spec priority_class(t(), String.t()) :: t()
  def priority_class(opts, name) when is_binary(name) do
    %{opts | priority_class: name}
  end

  @doc "Sets the service account."
  @spec service_account(t(), String.t()) :: t()
  def service_account(opts, name) when is_binary(name) do
    %{opts | service_account: name}
  end

  @doc "Enables host networking."
  @spec host_network(t(), boolean()) :: t()
  def host_network(opts, enabled \\ true) do
    %{opts | host_network: enabled}
  end

  @doc "Sets the DNS policy."
  @spec dns_policy(t(), String.t()) :: t()
  def dns_policy(opts, policy) when is_binary(policy) do
    %{opts | dns_policy: policy}
  end

  @doc "Sets a pod label."
  @spec label(t(), String.t(), String.t()) :: t()
  def label(opts, key, value) do
    %{opts | labels: Map.put(opts.labels, key, value)}
  end

  @doc "Sets a pod annotation."
  @spec annotation(t(), String.t(), String.t()) :: t()
  def annotation(opts, key, value) do
    %{opts | annotations: Map.put(opts.annotations, key, value)}
  end

  @doc "Sets security context to run as non-root."
  @spec run_as_non_root(t()) :: t()
  def run_as_non_root(opts) do
    ctx = opts.security_context || %{}
    %{opts | security_context: Map.put(ctx, :run_as_non_root, true)}
  end

  @doc "Sets the user ID to run as."
  @spec run_as_user(t(), integer()) :: t()
  def run_as_user(opts, uid) when is_integer(uid) do
    ctx = opts.security_context || %{}
    %{opts | security_context: Map.put(ctx, :run_as_user, uid)}
  end

  @doc "Adds a volume from a ConfigMap."
  @spec mount_config_map(t(), String.t(), String.t()) :: t()
  def mount_config_map(opts, name, mount_path) do
    vol = %{name: name, mount_path: mount_path, config_map: name}
    %{opts | volumes: opts.volumes ++ [vol]}
  end

  @doc "Adds a volume from a Secret."
  @spec mount_secret(t(), String.t(), String.t()) :: t()
  def mount_secret(opts, name, mount_path) do
    vol = %{name: name, mount_path: mount_path, secret: name}
    %{opts | volumes: opts.volumes ++ [vol]}
  end

  @doc "Adds an emptyDir volume."
  @spec mount_empty_dir(t(), String.t(), String.t(), keyword()) :: t()
  def mount_empty_dir(opts, name, mount_path, volume_opts \\ []) do
    empty_dir = %{
      medium: Keyword.get(volume_opts, :medium),
      size_limit: Keyword.get(volume_opts, :size_limit)
    }
    vol = %{name: name, mount_path: mount_path, empty_dir: empty_dir}
    %{opts | volumes: opts.volumes ++ [vol]}
  end

  @doc "Adds a PVC volume."
  @spec mount_pvc(t(), String.t(), String.t()) :: t()
  def mount_pvc(opts, claim_name, mount_path) do
    vol = %{name: claim_name, mount_path: mount_path, pvc: claim_name}
    %{opts | volumes: opts.volumes ++ [vol]}
  end

  # =============================================================================
  # VALIDATION
  # =============================================================================

  # Memory pattern: Ki, Mi, Gi, Ti, Pi, Ei (binary) or k, M, G, T, P, E (decimal)
  @memory_pattern ~r/^[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$/

  # CPU pattern: whole numbers, decimals, or millicores
  @cpu_pattern ~r/^[0-9]+(\.[0-9]+)?m?$/

  @doc """
  Validates K8s options. Returns {:ok, opts} or {:error, errors}.

  ## Examples

      iex> K8s.validate(K8s.options() |> K8s.memory("4Gi"))
      {:ok, %Sykli.K8s{...}}

      iex> K8s.validate(K8s.options() |> K8s.memory("4gb"))
      {:error, [%Sykli.K8s.ValidationError{field: "resources.memory", ...}]}
  """
  @spec validate(t()) :: {:ok, t()} | {:error, [ValidationError.t()]}
  def validate(opts) do
    errors = List.flatten([
      validate_resources(opts.resources),
      validate_tolerations(opts.tolerations),
      validate_dns_policy(opts.dns_policy),
      validate_volumes(opts.volumes)
    ])

    case errors do
      [] -> {:ok, opts}
      errors -> {:error, errors}
    end
  end

  @doc """
  Validates K8s options. Raises on errors.
  """
  @spec validate!(t()) :: t()
  def validate!(opts) do
    case validate(opts) do
      {:ok, opts} -> opts
      {:error, [first | _rest]} -> raise first
    end
  end

  defp validate_resources(resources) when map_size(resources) == 0, do: []
  defp validate_resources(resources) do
    memory_fields = [
      {:memory, Map.get(resources, :memory)},
      {:request_memory, Map.get(resources, :request_memory)},
      {:limit_memory, Map.get(resources, :limit_memory)}
    ]

    cpu_fields = [
      {:cpu, Map.get(resources, :cpu)},
      {:request_cpu, Map.get(resources, :request_cpu)},
      {:limit_cpu, Map.get(resources, :limit_cpu)}
    ]

    memory_errors = Enum.flat_map(memory_fields, fn {field, value} ->
      validate_memory("resources.#{field}", value)
    end)

    cpu_errors = Enum.flat_map(cpu_fields, fn {field, value} ->
      validate_cpu("resources.#{field}", value)
    end)

    memory_errors ++ cpu_errors
  end

  defp validate_memory(_field, nil), do: []
  defp validate_memory(field, value) do
    if Regex.match?(@memory_pattern, value) do
      []
    else
      # Provide helpful suggestions for common mistakes
      lower = String.downcase(value)
      suggestion = cond do
        String.ends_with?(lower, "gb") -> " (did you mean 'Gi'?)"
        String.ends_with?(lower, "mb") -> " (did you mean 'Mi'?)"
        String.ends_with?(lower, "kb") -> " (did you mean 'Ki'?)"
        true -> ""
      end

      [%ValidationError{
        field: field,
        value: value,
        message: "invalid memory format, use Ki/Mi/Gi/Ti (e.g., '512Mi', '4Gi')#{suggestion}"
      }]
    end
  end

  defp validate_cpu(_field, nil), do: []
  defp validate_cpu(field, value) do
    if Regex.match?(@cpu_pattern, value) do
      []
    else
      [%ValidationError{
        field: field,
        value: value,
        message: "invalid CPU format, use cores or millicores (e.g., '500m', '0.5', '2')"
      }]
    end
  end

  @valid_operators ["Exists", "Equal"]
  @valid_effects ["NoSchedule", "PreferNoSchedule", "NoExecute"]

  defp validate_tolerations(tolerations) do
    tolerations
    |> Enum.with_index()
    |> Enum.flat_map(fn {tol, i} ->
      operator_error = if tol.operator not in @valid_operators do
        [%ValidationError{
          field: "tolerations[#{i}].operator",
          value: tol.operator,
          message: "must be 'Exists' or 'Equal'"
        }]
      else
        []
      end

      effect_error = if tol.effect not in @valid_effects do
        [%ValidationError{
          field: "tolerations[#{i}].effect",
          value: tol.effect,
          message: "must be 'NoSchedule', 'PreferNoSchedule', or 'NoExecute'"
        }]
      else
        []
      end

      operator_error ++ effect_error
    end)
  end

  @valid_dns_policies ["ClusterFirst", "ClusterFirstWithHostNet", "Default", "None"]

  defp validate_dns_policy(nil), do: []
  defp validate_dns_policy(policy) do
    if policy in @valid_dns_policies do
      []
    else
      [%ValidationError{
        field: "dnsPolicy",
        value: policy,
        message: "must be one of: #{Enum.join(@valid_dns_policies, ", ")}"
      }]
    end
  end

  defp validate_volumes(volumes) do
    volumes
    |> Enum.with_index()
    |> Enum.flat_map(fn {vol, i} ->
      name_error = if is_nil(vol[:name]) or vol[:name] == "" do
        [%ValidationError{
          field: "volumes[#{i}].name",
          value: vol[:name],
          message: "volume name is required"
        }]
      else
        []
      end

      mount_path = vol[:mount_path]
      mount_error = cond do
        is_nil(mount_path) or mount_path == "" ->
          [%ValidationError{
            field: "volumes[#{i}].mountPath",
            value: mount_path,
            message: "mount path is required"
          }]
        not String.starts_with?(mount_path, "/") ->
          [%ValidationError{
            field: "volumes[#{i}].mountPath",
            value: mount_path,
            message: "mount path must be absolute (start with /)"
          }]
        true ->
          []
      end

      name_error ++ mount_error
    end)
  end

  # =============================================================================
  # JSON SERIALIZATION
  # =============================================================================

  @doc "Converts K8s options to a JSON-serializable map."
  @spec to_json(t()) :: map() | nil
  def to_json(%__MODULE__{} = opts) do
    base = %{}

    base
    |> maybe_put(:namespace, opts.namespace)
    |> maybe_put(:node_selector, non_empty_map(opts.node_selector))
    |> maybe_put(:tolerations, non_empty_list(opts.tolerations, &toleration_to_json/1))
    |> maybe_put(:affinity, opts.affinity)
    |> maybe_put(:priority_class_name, opts.priority_class)
    |> maybe_put(:resources, resources_to_json(opts.resources))
    |> maybe_put(:gpu, opts.gpu)
    |> maybe_put(:service_account, opts.service_account)
    |> maybe_put(:security_context, security_context_to_json(opts.security_context))
    |> maybe_put(:host_network, if(opts.host_network, do: true, else: nil))
    |> maybe_put(:dns_policy, opts.dns_policy)
    |> maybe_put(:volumes, non_empty_list(opts.volumes, &volume_to_json/1))
    |> maybe_put(:labels, non_empty_map(opts.labels))
    |> maybe_put(:annotations, non_empty_map(opts.annotations))
    |> non_empty_map()
  end

  defp resources_to_json(resources) when map_size(resources) == 0, do: nil
  defp resources_to_json(resources) do
    %{}
    |> maybe_put(:cpu, resources[:cpu])
    |> maybe_put(:memory, resources[:memory])
    |> maybe_put(:request_cpu, resources[:request_cpu])
    |> maybe_put(:request_memory, resources[:request_memory])
    |> maybe_put(:limit_cpu, resources[:limit_cpu])
    |> maybe_put(:limit_memory, resources[:limit_memory])
    |> non_empty_map()
  end

  defp toleration_to_json(tol) do
    %{key: tol.key, operator: tol.operator, effect: tol.effect}
    |> maybe_put(:value, tol.value)
  end

  defp security_context_to_json(nil), do: nil
  defp security_context_to_json(ctx) do
    %{}
    |> maybe_put(:run_as_user, ctx[:run_as_user])
    |> maybe_put(:run_as_group, ctx[:run_as_group])
    |> maybe_put(:run_as_non_root, ctx[:run_as_non_root])
    |> maybe_put(:privileged, ctx[:privileged])
    |> maybe_put(:read_only_root_filesystem, ctx[:read_only_root_fs])
    |> maybe_put(:add_capabilities, non_empty(ctx[:add_capabilities]))
    |> maybe_put(:drop_capabilities, non_empty(ctx[:drop_capabilities]))
    |> non_empty_map()
  end

  defp volume_to_json(vol) do
    base = %{name: vol[:name], mount_path: vol[:mount_path]}

    base
    |> maybe_put(:config_map, vol[:config_map])
    |> maybe_put(:secret, vol[:secret])
    |> maybe_put(:empty_dir, empty_dir_to_json(vol[:empty_dir]))
    |> maybe_put(:host_path, host_path_to_json(vol[:host_path]))
    |> maybe_put(:pvc, vol[:pvc])
  end

  defp empty_dir_to_json(nil), do: nil
  defp empty_dir_to_json(ed) do
    %{}
    |> maybe_put(:medium, ed[:medium])
    |> maybe_put(:size_limit, ed[:size_limit])
    |> non_empty_map()
  end

  defp host_path_to_json(nil), do: nil
  defp host_path_to_json(hp) do
    %{path: hp[:path]}
    |> maybe_put(:type, hp[:type])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_empty(nil), do: nil
  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp non_empty_map(nil), do: nil
  defp non_empty_map(map) when map_size(map) == 0, do: nil
  defp non_empty_map(map), do: map

  defp non_empty_list([], _), do: nil
  defp non_empty_list(list, mapper), do: Enum.map(list, mapper)
end
