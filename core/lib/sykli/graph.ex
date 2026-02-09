defmodule Sykli.Graph do
  @moduledoc """
  Parses task graph JSON and performs topological sort.
  """

  alias Sykli.Error

  defmodule Service do
    @moduledoc "Represents a service container for a task"
    defstruct [:image, :name]
  end

  defmodule TaskInput do
    @moduledoc "Represents an input artifact from another task's output"
    defstruct [:from_task, :output, :dest]
  end

  defmodule Task do
    @moduledoc """
    Represents a single task in the pipeline.

    ## Field Organization

    Fields are organized into logical groups (accessible via sub-structs
    for DDD purposes, while maintaining backward compatibility):

    **Execution** - Core execution properties
      - `name`, `command`, `container`, `workdir`, `timeout`

    **Caching** - Cache-related properties
      - `inputs`, `outputs`, `task_inputs`

    **Dependencies** - Ordering and conditions
      - `depends_on`, `condition`, `matrix`, `matrix_values`

    **Robustness** - Reliability and security
      - `retry`, `secrets`, `env`

    **Infrastructure** - Environment configuration
      - `mounts`, `services`, `k8s`, `requires`

    **AI-Native** - Metadata for AI assistants
      - `semantic` - what code this task covers, intent, criticality
      - `ai_hooks` - on_fail behavior, task selection mode
      - `history_hint` - learned data (flakiness, duration, patterns)

    ## Accessor Functions

    Use the accessor functions to access fields - they provide a consistent
    interface and will work with both the flat struct and future sub-struct
    organization.
    """

    alias Sykli.Graph.Task.Execution
    alias Sykli.Graph.Task.Caching
    alias Sykli.Graph.Task.Dependencies
    alias Sykli.Graph.Task.Robustness
    alias Sykli.Graph.Task.Infrastructure
    alias Sykli.Graph.Task.Semantic
    alias Sykli.Graph.Task.AiHooks
    alias Sykli.Graph.Task.HistoryHint
    alias Sykli.Graph.Task.Capability
    alias Sykli.Graph.Task.Gate

    defstruct [
      :name,
      :command,
      :inputs,
      :outputs,
      :depends_on,
      :condition,
      # CI features
      # List of required secret environment variables
      :secrets,
      # Map of matrix dimensions (key -> [values])
      :matrix,
      # Specific values for expanded tasks (key -> value)
      :matrix_values,
      # List of service containers (image, name)
      :services,
      # Robustness features
      # Number of retries on failure (nil = no retry)
      :retry,
      # Timeout in seconds (nil = default 5 min)
      :timeout,
      # v2 fields
      # Docker image to run in
      :container,
      # Working directory inside container
      :workdir,
      # Environment variables (map)
      :env,
      # List of mounts (directories and caches)
      :mounts,
      # List of TaskInput structs (artifact bindings from other tasks)
      :task_inputs,
      # Target-specific options
      # Sykli.Target.K8sOptions - only used with K8s target
      :k8s,
      # Node placement
      # List of required node labels (e.g., ["gpu", "docker"])
      :requires,
      # AI-native fields
      # Semantic metadata for AI understanding
      :semantic,
      # AI behavioral hooks
      :ai_hooks,
      # Learned history hints (populated by Sykli, not SDKs)
      :history_hint,
      # Capability-based dependencies (provides/needs)
      :capability,
      # Gate (approval point)
      :gate,
      # OIDC credential binding
      :oidc,
      # Cross-platform verification mode ("cross_platform", "always", "never", or nil)
      :verify
    ]

    @type t :: %__MODULE__{}

    # ─────────────────────────────────────────────────────────────────────────────
    # ACCESSOR FUNCTIONS
    # ─────────────────────────────────────────────────────────────────────────────

    @doc "Returns the task name."
    @spec name(t()) :: String.t()
    def name(%__MODULE__{name: n}), do: n

    @doc "Returns the task command."
    @spec command(t()) :: String.t()
    def command(%__MODULE__{command: c}), do: c

    @doc "Returns the container image (or nil for shell execution)."
    @spec container(t()) :: String.t() | nil
    def container(%__MODULE__{container: c}), do: c

    @doc "Returns the working directory."
    @spec workdir(t()) :: String.t() | nil
    def workdir(%__MODULE__{workdir: w}), do: w

    @doc "Returns the timeout in seconds."
    @spec timeout(t()) :: pos_integer() | nil
    def timeout(%__MODULE__{timeout: t}), do: t

    @doc "Returns the list of input patterns."
    @spec inputs(t()) :: [String.t()]
    def inputs(%__MODULE__{inputs: i}), do: i || []

    @doc "Returns the outputs (map or list)."
    @spec outputs(t()) :: map() | [String.t()]
    def outputs(%__MODULE__{outputs: o}), do: o || %{}

    @doc "Returns the list of task dependencies."
    @spec depends_on(t()) :: [String.t()]
    def depends_on(%__MODULE__{depends_on: d}), do: d || []

    @doc "Returns the condition expression."
    @spec condition(t()) :: String.t() | nil
    def condition(%__MODULE__{condition: c}), do: c

    @doc "Returns the retry count."
    @spec retry(t()) :: non_neg_integer() | nil
    def retry(%__MODULE__{retry: r}), do: r

    @doc "Returns the list of required secrets."
    @spec secrets(t()) :: [String.t()]
    def secrets(%__MODULE__{secrets: s}), do: s || []

    @doc "Returns the environment variables map."
    @spec env(t()) :: map()
    def env(%__MODULE__{env: e}), do: e || %{}

    @doc "Returns the list of mounts."
    @spec mounts(t()) :: [map()]
    def mounts(%__MODULE__{mounts: m}), do: m || []

    @doc "Returns the list of services."
    @spec services(t()) :: [Sykli.Graph.Service.t()]
    def services(%__MODULE__{services: s}), do: s || []

    @doc "Returns the K8s options."
    @spec k8s(t()) :: Sykli.Target.K8sOptions.t() | nil
    def k8s(%__MODULE__{k8s: k}), do: k

    @doc "Returns the node requirements."
    @spec requires(t()) :: [String.t()]
    def requires(%__MODULE__{requires: r}), do: r || []

    @doc "Returns the task inputs (artifact dependencies)."
    @spec task_inputs(t()) :: [Sykli.Graph.TaskInput.t()]
    def task_inputs(%__MODULE__{task_inputs: ti}), do: ti || []

    @doc "Returns the semantic metadata."
    @spec semantic(t()) :: Semantic.t()
    def semantic(%__MODULE__{semantic: s}), do: s || %Semantic{}

    @doc "Returns the AI hooks."
    @spec ai_hooks(t()) :: AiHooks.t()
    def ai_hooks(%__MODULE__{ai_hooks: h}), do: h || %AiHooks{}

    @doc "Returns the history hints."
    @spec history_hint(t()) :: HistoryHint.t()
    def history_hint(%__MODULE__{history_hint: h}), do: h || %HistoryHint{}

    @doc "Returns the capability metadata."
    @spec capability(t()) :: Capability.t() | nil
    def capability(%__MODULE__{capability: c}), do: c

    # ─────────────────────────────────────────────────────────────────────────────
    # SUB-STRUCT ACCESSORS
    # ─────────────────────────────────────────────────────────────────────────────

    @doc "Returns the execution sub-struct."
    @spec execution(t()) :: Execution.t()
    def execution(%__MODULE__{} = task), do: Execution.from_task(task)

    @doc "Returns the caching sub-struct."
    @spec caching(t()) :: Caching.t()
    def caching(%__MODULE__{} = task), do: Caching.from_task(task)

    @doc "Returns the dependencies sub-struct."
    @spec dependencies(t()) :: Dependencies.t()
    def dependencies(%__MODULE__{} = task), do: Dependencies.from_task(task)

    @doc "Returns the robustness sub-struct."
    @spec robustness(t()) :: Robustness.t()
    def robustness(%__MODULE__{} = task), do: Robustness.from_task(task)

    @doc "Returns the infrastructure sub-struct."
    @spec infrastructure(t()) :: Infrastructure.t()
    def infrastructure(%__MODULE__{} = task), do: Infrastructure.from_task(task)

    # ─────────────────────────────────────────────────────────────────────────────
    # PREDICATES
    # ─────────────────────────────────────────────────────────────────────────────

    @doc "Checks if the task uses a container."
    @spec containerized?(t()) :: boolean()
    def containerized?(%__MODULE__{container: c}), do: c != nil && c != ""

    @doc "Checks if the task is cacheable (has inputs defined)."
    @spec cacheable?(t()) :: boolean()
    def cacheable?(%__MODULE__{inputs: i}), do: i != nil && i != []

    @doc "Checks if the task has retry enabled."
    @spec retriable?(t()) :: boolean()
    def retriable?(%__MODULE__{retry: r}), do: r != nil && r > 0

    @doc "Checks if the task has a condition."
    @spec conditional?(t()) :: boolean()
    def conditional?(%__MODULE__{condition: c}), do: c != nil && c != ""

    @doc "Checks if this is a matrix task (before expansion)."
    @spec matrix?(t()) :: boolean()
    def matrix?(%__MODULE__{matrix: m}), do: m != nil && map_size(m) > 0

    @doc "Checks if this is an expanded matrix task."
    @spec expanded_matrix?(t()) :: boolean()
    def expanded_matrix?(%__MODULE__{matrix_values: mv}), do: mv != nil && map_size(mv) > 0

    @doc "Checks if the task has semantic metadata."
    @spec has_semantic?(t()) :: boolean()
    def has_semantic?(%__MODULE__{semantic: nil}), do: false
    def has_semantic?(%__MODULE__{semantic: %Semantic{covers: [], intent: nil}}), do: false
    def has_semantic?(_), do: true

    @doc "Checks if the task has AI hooks configured."
    @spec has_ai_hooks?(t()) :: boolean()
    def has_ai_hooks?(%__MODULE__{ai_hooks: nil}), do: false
    def has_ai_hooks?(%__MODULE__{ai_hooks: %AiHooks{on_fail: nil, select: nil}}), do: false
    def has_ai_hooks?(_), do: true

    @doc "Checks if the task uses smart selection."
    @spec smart_select?(t()) :: boolean()
    def smart_select?(%__MODULE__{ai_hooks: %AiHooks{select: :smart}}), do: true
    def smart_select?(_), do: false

    @doc "Checks if the task is critical."
    @spec critical?(t()) :: boolean()
    def critical?(%__MODULE__{semantic: %Semantic{criticality: :high}}), do: true
    def critical?(_), do: false

    @doc "Checks if the task is flaky."
    @spec flaky?(t()) :: boolean()
    def flaky?(%__MODULE__{history_hint: %HistoryHint{flaky: true}}), do: true
    def flaky?(_), do: false

    @doc "Checks if the task has capability metadata (provides or needs)."
    @spec has_capability?(t()) :: boolean()
    def has_capability?(%__MODULE__{capability: nil}), do: false
    def has_capability?(%__MODULE__{capability: %Capability{provides: [], needs: []}}), do: false
    def has_capability?(_), do: true

    @doc "Checks if this is a gate (approval point)."
    @spec gate?(t()) :: boolean()
    def gate?(%__MODULE__{gate: nil}), do: false
    def gate?(%__MODULE__{gate: %Gate{}}), do: true
    def gate?(_), do: false

    @doc "Returns the gate metadata."
    def gate(%__MODULE__{gate: g}), do: g
  end

  def parse(json) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => tasks}} ->
        case map_ok(tasks, &parse_task/1) do
          {:ok, parsed_tasks} ->
            parsed = Map.new(parsed_tasks, fn task -> {task.name, task} end)
            {:ok, parsed}

          {:error, _} = error ->
            error
        end

      {:ok, _} ->
        {:error, :invalid_format}

      {:error, reason} ->
        {:error, {:json_parse_error, reason}}
    end
  end

  defp parse_task(map) do
    task_name = map["name"]

    with {:ok, services} <- parse_services(map["services"], task_name),
         {:ok, mounts} <- parse_mounts(map["mounts"], task_name) do
      {:ok,
       %Task{
         name: task_name,
         command: map["command"],
         inputs: map["inputs"] || [],
         outputs: normalize_outputs(map["outputs"]),
         depends_on: (map["depends_on"] || []) |> Enum.uniq(),
         condition: map["when"] || map["condition"],
         # CI features
         secrets: map["secrets"] || [],
         matrix: map["matrix"],
         matrix_values: nil,
         services: services,
         # Robustness features
         retry: map["retry"],
         timeout: map["timeout"],
         # v2 fields
         container: map["container"],
         workdir: map["workdir"],
         env: map["env"] || %{},
         mounts: mounts,
         task_inputs: parse_task_inputs(map["task_inputs"]),
         # Target-specific options
         k8s: Sykli.Target.K8sOptions.parse(map["k8s"]),
         # Node placement
         requires: map["requires"] || [],
         # AI-native fields
         semantic: Task.Semantic.from_map(map["semantic"]),
         ai_hooks: Task.AiHooks.from_map(map["ai_hooks"]),
         history_hint: Task.HistoryHint.from_map(map["history_hint"]),
         capability:
           Task.Capability.from_map(%{"provides" => map["provides"], "needs" => map["needs"]}),
         gate: Task.Gate.from_map(map["gate"]),
         oidc: Task.CredentialBinding.from_map(map["oidc"]),
         verify: map["verify"]
       }}
    end
  end

  defp parse_task_inputs(nil), do: []

  defp parse_task_inputs(task_inputs) when is_list(task_inputs) do
    Enum.map(task_inputs, fn ti ->
      %TaskInput{
        from_task: ti["from_task"],
        output: ti["output"],
        dest: ti["dest"]
      }
    end)
  end

  defp parse_services(nil, _task_name), do: {:ok, []}

  defp parse_services(services, task_name) when is_list(services) do
    map_ok(services, fn s ->
      image = s["image"]
      name = s["name"]

      cond do
        is_nil(image) or image == "" ->
          {:error, Error.invalid_service(:image, name) |> Error.with_task(task_name)}

        is_nil(name) or name == "" ->
          {:error, Error.invalid_service(:name) |> Error.with_task(task_name)}

        true ->
          {:ok, %Service{image: image, name: name}}
      end
    end)
  end

  defp parse_mounts(nil, _task_name), do: {:ok, []}

  defp parse_mounts(mounts, task_name) when is_list(mounts) do
    map_ok(mounts, fn m ->
      resource = m["resource"]
      path = m["path"]
      type = m["type"]

      cond do
        is_nil(resource) or resource == "" ->
          {:error, Error.invalid_mount(:resource) |> Error.with_task(task_name)}

        is_nil(path) or path == "" ->
          {:error, Error.invalid_mount(:path) |> Error.with_task(task_name)}

        is_nil(type) or type not in ["directory", "cache"] ->
          {:error,
           Error.invalid_mount(:type, "got: #{inspect(type)}") |> Error.with_task(task_name)}

        true ->
          {:ok, %{resource: resource, path: path, type: type}}
      end
    end)
  end

  # Handle both v1 (list) and v2 (map) output formats
  # v2 keeps outputs as map for named artifact passing
  defp normalize_outputs(nil), do: %{}

  defp normalize_outputs(outputs) when is_list(outputs) do
    # v1: list of paths - convert to auto-named map for consistency
    outputs
    |> Enum.with_index()
    |> Map.new(fn {path, idx} -> {"output_#{idx}", path} end)
  end

  defp normalize_outputs(outputs) when is_map(outputs), do: outputs

  @doc """
  Expands matrix tasks into individual tasks.
  A task with matrix: {"os": ["linux", "macos"], "version": ["1.0", "2.0"]}
  becomes 4 tasks: task-1.0-linux, task-1.0-macos, task-2.0-linux, task-2.0-macos
  (suffix order is deterministic based on sorted keys)
  """
  def expand_matrix(graph) do
    # Collect all expanded tasks and original task names that were expanded
    {expanded_tasks, expanded_names} =
      graph
      |> Enum.reduce({%{}, MapSet.new()}, fn {name, task}, {acc_tasks, acc_names} ->
        case task.matrix do
          nil ->
            {Map.put(acc_tasks, name, task), acc_names}

          matrix when map_size(matrix) == 0 ->
            {Map.put(acc_tasks, name, task), acc_names}

          matrix ->
            # Generate all combinations
            combinations = matrix_combinations(matrix)

            # Create expanded tasks
            new_tasks =
              combinations
              |> Enum.map(fn combo ->
                # Sort by key for deterministic suffix
                suffix = combo |> Enum.sort() |> Enum.map(fn {_k, v} -> v end) |> Enum.join("-")
                new_name = "#{name}-#{suffix}"

                # Merge matrix values into env
                new_env = Map.merge(task.env || %{}, combo)

                %{task | name: new_name, matrix: nil, matrix_values: combo, env: new_env}
              end)
              |> Map.new(fn t -> {t.name, t} end)

            {Map.merge(acc_tasks, new_tasks), MapSet.put(acc_names, name)}
        end
      end)

    # Update dependencies: if a task depends on an expanded task,
    # it should depend on ALL expanded variants
    expanded_tasks
    |> Enum.map(fn {name, task} ->
      new_deps =
        (task.depends_on || [])
        |> Enum.flat_map(fn dep ->
          if MapSet.member?(expanded_names, dep) do
            # Find all expanded variants of this dependency
            expanded_tasks
            |> Map.keys()
            |> Enum.filter(&String.starts_with?(&1, "#{dep}-"))
          else
            [dep]
          end
        end)

      {name, %{task | depends_on: new_deps}}
    end)
    |> Map.new()
  end

  # Generate all combinations of matrix dimensions
  defp matrix_combinations(matrix) when map_size(matrix) == 0, do: [%{}]

  defp matrix_combinations(matrix) do
    [{key, values} | rest] = Map.to_list(matrix)
    rest_combinations = matrix_combinations(Map.new(rest))

    for value <- values, combo <- rest_combinations do
      Map.put(combo, key, value)
    end
  end

  @doc """
  Topological sort using Kahn's algorithm.
  Returns tasks in execution order.
  """
  def topo_sort(graph) do
    # Build in-degree map
    in_degree =
      graph
      |> Map.keys()
      |> Map.new(fn name -> {name, 0} end)

    in_degree =
      Enum.reduce(graph, in_degree, fn {_name, task}, acc ->
        Enum.reduce(task.depends_on || [], acc, fn dep, acc2 ->
          Map.update(acc2, dep, 0, & &1)
        end)
      end)

    in_degree =
      Enum.reduce(graph, in_degree, fn {_name, task}, acc ->
        Enum.reduce(task.depends_on || [], acc, fn _dep, acc2 ->
          Map.update!(acc2, task.name, &(&1 + 1))
        end)
      end)

    # Find all nodes with no incoming edges
    queue =
      in_degree
      |> Enum.filter(fn {_name, deg} -> deg == 0 end)
      |> Enum.map(fn {name, _} -> name end)

    do_topo_sort(queue, in_degree, graph, [])
  end

  defp do_topo_sort([], in_degree, graph, result) do
    remaining = Enum.filter(in_degree, fn {_, deg} -> deg > 0 end)

    if remaining == [] do
      {:ok, Enum.reverse(result)}
    else
      # Find the actual cycle path using DFS
      cycle_path = detect_cycle(graph)
      {:error, {:cycle_detected, cycle_path}}
    end
  end

  defp do_topo_sort([current | rest], in_degree, graph, result) do
    task = Map.get(graph, current)

    # Find tasks that depend on current
    dependents =
      graph
      |> Enum.filter(fn {_name, t} -> current in (t.depends_on || []) end)
      |> Enum.map(fn {name, _} -> name end)

    # Decrease in-degree for dependents
    {new_in_degree, new_queue} =
      Enum.reduce(dependents, {in_degree, rest}, fn dep, {deg_acc, queue_acc} ->
        new_deg = Map.update!(deg_acc, dep, &(&1 - 1))

        if new_deg[dep] == 0 do
          {new_deg, queue_acc ++ [dep]}
        else
          {new_deg, queue_acc}
        end
      end)

    new_in_degree = Map.put(new_in_degree, current, -1)

    result = if task, do: [task | result], else: result
    do_topo_sort(new_queue, new_in_degree, graph, result)
  end

  @doc """
  Detects cycles in the task graph using DFS with three-color marking.
  Returns the cycle path if found, empty list otherwise.
  """
  def detect_cycle(graph) do
    # Build adjacency map: task name -> dependencies
    deps = Map.new(graph, fn {name, task} -> {name, task.depends_on || []} end)

    # Colors: :white (unvisited), :gray (in progress), :black (done)
    initial_color = Map.new(Map.keys(graph), fn name -> {name, :white} end)

    # DFS from each unvisited node
    result =
      Enum.reduce_while(Map.keys(graph), {initial_color, %{}, nil}, fn name, {color, parent, _} ->
        if color[name] == :white do
          case dfs_detect_cycle(name, deps, color, parent) do
            {:cycle, path} -> {:halt, {color, parent, path}}
            {:ok, new_color, new_parent} -> {:cont, {new_color, new_parent, nil}}
          end
        else
          {:cont, {color, parent, nil}}
        end
      end)

    case result do
      {_, _, nil} -> []
      {_, _, path} -> path
    end
  end

  defp dfs_detect_cycle(node, deps, color, parent) do
    color = Map.put(color, node, :gray)

    node_deps = Map.get(deps, node, [])

    result =
      Enum.reduce_while(node_deps, {:ok, color, parent}, fn dep, {:ok, c, p} ->
        cond do
          c[dep] == :gray ->
            # Found a cycle - reconstruct the path
            path = reconstruct_cycle(node, dep, p)
            {:halt, {:cycle, path}}

          c[dep] == :white ->
            p = Map.put(p, dep, node)

            case dfs_detect_cycle(dep, deps, c, p) do
              {:cycle, path} -> {:halt, {:cycle, path}}
              {:ok, new_c, new_p} -> {:cont, {:ok, new_c, new_p}}
            end

          true ->
            {:cont, {:ok, c, p}}
        end
      end)

    case result do
      {:cycle, path} -> {:cycle, path}
      {:ok, c, p} -> {:ok, Map.put(c, node, :black), p}
    end
  end

  defp reconstruct_cycle(from, to, parent) do
    # Cycle: to -> ... -> from -> to
    build_cycle_path(from, to, parent, [to])
  end

  defp build_cycle_path(current, target, parent, path) do
    if current == target do
      [target | path]
    else
      build_cycle_path(Map.get(parent, current, target), target, parent, [current | path])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ARTIFACT GRAPH VALIDATION
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Check if a graph has any artifact dependencies (task_inputs).

  This is useful to determine if artifact passing is needed at all,
  allowing targets to fail-fast if they don't support it.
  """
  def has_artifact_dependencies?(graph) do
    Enum.any?(graph, fn {_name, task} ->
      task_inputs = task.task_inputs || []
      length(task_inputs) > 0
    end)
  end

  @doc """
  Validates the artifact dependency graph.

  Checks:
  1. All task_inputs reference existing tasks
  2. All task_inputs reference declared outputs
  3. Artifact dependencies imply task dependencies (to ensure ordering)

  Returns :ok or {:error, reason}.
  """
  def validate_artifacts(graph) do
    # Build transitive dependency map for checking ordering
    transitive_deps = build_transitive_deps(graph)

    # Check each task's task_inputs
    graph
    |> Enum.reduce_while(:ok, fn {task_name, task}, :ok ->
      case validate_task_inputs(task_name, task.task_inputs || [], graph, transitive_deps) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_task_inputs(_task_name, [], _graph, _transitive_deps), do: :ok

  defp validate_task_inputs(task_name, [input | rest], graph, transitive_deps) do
    %TaskInput{from_task: from_task, output: output_name} = input

    cond do
      # 1. Check source task exists
      not Map.has_key?(graph, from_task) ->
        {:error, {:source_task_not_found, task_name, from_task}}

      # 2. Check output is declared
      not output_declared?(graph, from_task, output_name) ->
        {:error, {:output_not_found, task_name, from_task, output_name}}

      # 3. Check task dependency exists (direct or transitive)
      not task_depends_on?(task_name, from_task, transitive_deps) ->
        {:error, {:missing_task_dependency, task_name, from_task}}

      true ->
        validate_task_inputs(task_name, rest, graph, transitive_deps)
    end
  end

  defp output_declared?(graph, task_name, output_name) do
    task = Map.get(graph, task_name)
    outputs = task.outputs || %{}

    # Handle both map and list formats
    case outputs do
      map when is_map(map) -> Map.has_key?(map, output_name)
      list when is_list(list) -> output_name in list
    end
  end

  defp task_depends_on?(task_name, dependency, transitive_deps) do
    deps = Map.get(transitive_deps, task_name, MapSet.new())
    MapSet.member?(deps, dependency)
  end

  # Build a map of task_name => set of all transitive dependencies
  defp build_transitive_deps(graph) do
    graph
    |> Map.keys()
    |> Enum.reduce(%{}, fn name, acc ->
      Map.put(acc, name, get_all_deps(name, graph, MapSet.new()))
    end)
  end

  defp get_all_deps(name, graph, visited) do
    if MapSet.member?(visited, name) do
      visited
    else
      task = Map.get(graph, name)
      direct_deps = (task && task.depends_on) || []

      Enum.reduce(direct_deps, MapSet.put(visited, name), fn dep, acc ->
        # Add direct dep and all its transitive deps
        acc
        |> MapSet.put(dep)
        |> MapSet.union(get_all_deps(dep, graph, acc))
      end)
      # Don't include self
      |> MapSet.delete(name)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  # Maps over a list with a function that returns {:ok, result} | {:error, reason}
  # Returns {:ok, results} or the first {:error, reason} encountered
  defp map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end
end
