defmodule Sykli.Emitter do
  @moduledoc """
  Validates pipelines and emits JSON output.
  """

  require Logger

  # ============================================================================
  # VALIDATION
  # ============================================================================

  @doc "Validates a pipeline, raises on errors."
  def validate!(pipeline) do
    task_names = MapSet.new(pipeline.tasks, & &1.name)

    # Check for duplicate task names
    if MapSet.size(task_names) != length(pipeline.tasks) do
      Logger.error("duplicate task names detected")
      raise "duplicate task names detected"
    end

    # Check all tasks have commands
    Enum.each(pipeline.tasks, fn task ->
      if is_nil(task.command) or task.command == "" do
        Logger.error("task has no command", task: task.name)
        raise "task #{inspect(task.name)} has no command"
      end
    end)

    # Check dependencies exist
    Enum.each(pipeline.tasks, fn task ->
      Enum.each(task.depends_on, fn dep ->
        unless MapSet.member?(task_names, dep) do
          Logger.error("unknown dependency", task: task.name, dependency: dep)
          raise "task #{inspect(task.name)} depends on unknown task #{inspect(dep)}"
        end
      end)
    end)

    # Check for cycles
    case detect_cycle(pipeline.tasks) do
      nil ->
        :ok

      cycle ->
        Logger.error("dependency cycle detected", cycle: cycle)
        raise "dependency cycle detected: #{Enum.join(cycle, " -> ")}"
    end

    Logger.debug("pipeline validated", tasks: length(pipeline.tasks))
    pipeline
  end

  # ============================================================================
  # CYCLE DETECTION (3-color DFS)
  # ============================================================================

  defp detect_cycle(tasks) do
    deps = Map.new(tasks, fn t -> {t.name, t.depends_on} end)
    names = Map.keys(deps)

    Enum.reduce_while(names, {%{}, nil}, fn name, {visited, _} ->
      case dfs_cycle(name, deps, visited, []) do
        {:cycle, path} -> {:halt, {visited, path}}
        {:ok, new_visited} -> {:cont, {new_visited, nil}}
      end
    end)
    |> elem(1)
  end

  defp dfs_cycle(node, deps, visited, path) do
    case Map.get(visited, node) do
      :done ->
        {:ok, visited}

      :visiting ->
        cycle_start = Enum.find_index(path, &(&1 == node))
        cycle = Enum.slice(path, cycle_start..-1//1) ++ [node]
        {:cycle, cycle}

      nil ->
        visited = Map.put(visited, node, :visiting)
        path = path ++ [node]

        result =
          Enum.reduce_while(Map.get(deps, node, []), {:ok, visited}, fn dep, {:ok, v} ->
            case dfs_cycle(dep, deps, v, path) do
              {:cycle, _} = cycle -> {:halt, cycle}
              {:ok, new_v} -> {:cont, {:ok, new_v}}
            end
          end)

        case result do
          {:cycle, _} = cycle -> cycle
          {:ok, visited} -> {:ok, Map.put(visited, node, :done)}
        end
    end
  end

  # ============================================================================
  # JSON SERIALIZATION
  # ============================================================================

  @doc "Converts pipeline to JSON string."
  def to_json(pipeline) do
    has_v2_features =
      map_size(pipeline.resources) > 0 or
        Enum.any?(pipeline.tasks, fn t ->
          t.container != nil or length(t.mounts) > 0
        end)

    version = if has_v2_features, do: "2", else: "1"

    Logger.debug("emitting pipeline", version: version, tasks: length(pipeline.tasks))

    output = %{
      version: version,
      tasks: Enum.map(pipeline.tasks, &task_to_json/1)
    }

    output =
      if has_v2_features do
        Map.put(output, :resources, resources_to_json(pipeline.resources))
      else
        output
      end

    Jason.encode!(output)
  end

  defp task_to_json(task) do
    %{name: task.name, command: task.command}
    |> maybe_put(:container, task.container)
    |> maybe_put(:workdir, task.workdir)
    |> maybe_put(:env, non_empty_map(task.env))
    |> maybe_put(:mounts, non_empty_list(task.mounts, &mount_to_json/1))
    |> maybe_put(:inputs, non_empty(task.inputs))
    |> maybe_put(:outputs, non_empty_map(task.outputs))
    |> maybe_put(:depends_on, non_empty(task.depends_on))
    |> maybe_put(:task_inputs, non_empty_list(task.task_inputs, &task_input_to_json/1))
    |> maybe_put(:when, task.condition)
    |> maybe_put(:secrets, non_empty(task.secrets))
    |> maybe_put(:matrix, non_empty_map(task.matrix))
    |> maybe_put(:services, non_empty_list(task.services, &service_to_json/1))
    |> maybe_put(:retry, task.retry)
    |> maybe_put(:timeout, task.timeout)
  end

  defp mount_to_json(mount) do
    %{resource: mount.resource, path: mount.path, type: Atom.to_string(mount.type)}
  end

  defp task_input_to_json(ti) do
    %{from_task: ti.from_task, output: ti.output, dest: ti.dest}
  end

  defp service_to_json(svc) do
    %{image: svc.image, name: svc.name}
  end

  defp resources_to_json(resources) do
    Map.new(resources, fn {name, r} ->
      json =
        case r.type do
          :directory ->
            %{type: "directory", path: r.path}
            |> maybe_put(:globs, non_empty(r.globs))

          :cache ->
            %{type: "cache", name: r.name}
        end

      {name, json}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp non_empty_map(map) when map_size(map) == 0, do: nil
  defp non_empty_map(map), do: map

  defp non_empty_list([], _), do: nil
  defp non_empty_list(list, mapper), do: Enum.map(list, mapper)
end
