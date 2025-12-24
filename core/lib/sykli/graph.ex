defmodule Sykli.Graph do
  @moduledoc """
  Parses task graph JSON and performs topological sort.
  """

  defmodule Service do
    @moduledoc "Represents a service container for a task"
    defstruct [:image, :name]
  end

  defmodule TaskInput do
    @moduledoc "Represents an input artifact from another task's output"
    defstruct [:from_task, :output, :dest]
  end

  defmodule Task do
    @moduledoc "Represents a single task in the pipeline"
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
      :task_inputs
    ]
  end

  def parse(json) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => tasks}} ->
        parsed =
          tasks
          |> Enum.map(&parse_task/1)
          |> Map.new(fn task -> {task.name, task} end)

        {:ok, parsed}

      {:ok, _} ->
        {:error, :invalid_format}

      {:error, reason} ->
        {:error, {:json_parse_error, reason}}
    end
  end

  defp parse_task(map) do
    %Task{
      name: map["name"],
      command: map["command"],
      inputs: map["inputs"] || [],
      outputs: normalize_outputs(map["outputs"]),
      depends_on: (map["depends_on"] || []) |> Enum.uniq(),
      condition: map["when"] || map["condition"],
      # CI features
      secrets: map["secrets"] || [],
      matrix: map["matrix"],
      matrix_values: nil,
      services: parse_services(map["services"]),
      # Robustness features
      retry: map["retry"],
      timeout: map["timeout"],
      # v2 fields
      container: map["container"],
      workdir: map["workdir"],
      env: map["env"] || %{},
      mounts: parse_mounts(map["mounts"]),
      task_inputs: parse_task_inputs(map["task_inputs"])
    }
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

  defp parse_services(nil), do: []

  defp parse_services(services) when is_list(services) do
    Enum.map(services, fn s ->
      image = s["image"]
      name = s["name"]

      if is_nil(image) or image == "" do
        raise "service image cannot be empty"
      end

      if is_nil(name) or name == "" do
        raise "service name cannot be empty"
      end

      %Service{image: image, name: name}
    end)
  end

  defp parse_mounts(nil), do: []

  defp parse_mounts(mounts) when is_list(mounts) do
    Enum.map(mounts, fn m ->
      resource = m["resource"]
      path = m["path"]
      type = m["type"]

      # Validate required fields
      if is_nil(resource) or resource == "" do
        raise "mount resource cannot be empty"
      end

      if is_nil(path) or path == "" do
        raise "mount path cannot be empty"
      end

      if is_nil(type) or type not in ["directory", "cache"] do
        raise "mount type must be 'directory' or 'cache'"
      end

      %{resource: resource, path: path, type: type}
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
end
