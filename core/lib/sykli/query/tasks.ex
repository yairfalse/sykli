defmodule Sykli.Query.Tasks do
  @moduledoc """
  Task structure queries: critical tasks, dependencies, details.
  """

  alias Sykli.Graph
  alias Sykli.Graph.Task
  alias Sykli.{Context, Explain}

  @spec execute(atom(), String.t() | tuple() | nil, String.t()) ::
          {:ok, map()} | {:error, term()}
  def execute(query_type, target, path) do
    with {:ok, graph} <- load_graph(path) do
      case query_type do
        :critical -> critical_tasks(graph)
        :deps -> dependencies_of(target, graph)
        :dependents -> dependents_of(target, graph)
        :details -> task_details(target, graph)
        :level -> tasks_in_level(target, graph)
        :path -> dependency_path(target, graph)
      end
    end
  end

  defp critical_tasks(graph) do
    tasks =
      graph
      |> Enum.filter(fn {_name, task} -> Task.critical?(task) end)
      |> Enum.map(fn {name, task} ->
        semantic = Task.semantic(task)

        %{
          name: name,
          intent: semantic.intent,
          criticality: if(semantic.criticality, do: Atom.to_string(semantic.criticality))
        }
      end)
      |> Enum.sort_by(& &1.name)

    {:ok,
     %{
       type: :tasks,
       data: %{query: :critical, tasks: tasks, total: length(tasks)},
       metadata: metadata("critical tasks")
     }}
  end

  defp dependencies_of(task_name, graph) do
    case Map.get(graph, task_name) do
      nil ->
        {:error, {:task_not_found, task_name}}

      task ->
        deps = Task.depends_on(task)

        {:ok,
         %{
           type: :tasks,
           data: %{query: :deps, task: task_name, dependencies: deps},
           metadata: metadata("dependencies of #{task_name}")
         }}
    end
  end

  defp dependents_of(task_name, graph) do
    unless Map.has_key?(graph, task_name) do
      {:error, {:task_not_found, task_name}}
    else
      blocks = Explain.compute_blocks(graph)
      dependents = Map.get(blocks, task_name, []) |> Enum.sort()

      {:ok,
       %{
         type: :tasks,
         data: %{query: :dependents, task: task_name, dependents: dependents},
         metadata: metadata("dependents of #{task_name}")
       }}
    end
  end

  defp task_details(task_name, graph) do
    case Map.get(graph, task_name) do
      nil ->
        {:error, {:task_not_found, task_name}}

      task ->
        {:ok,
         %{
           type: :tasks,
           data: %{query: :details, task: Context.task_to_map(task)},
           metadata: metadata("task #{task_name}")
         }}
    end
  end

  defp tasks_in_level(level_str, graph) do
    case Integer.parse(level_str) do
      {level, _} ->
        levels = Explain.compute_levels(graph)
        tasks_at_level = Map.get(levels, level, []) |> Enum.sort()

        {:ok,
         %{
           type: :tasks,
           data: %{
             query: :level,
             level: level,
             tasks: tasks_at_level,
             total: length(tasks_at_level)
           },
           metadata: metadata("tasks in level #{level}")
         }}

      :error ->
        {:error, {:invalid_level, level_str}}
    end
  end

  defp dependency_path({from, to}, graph) do
    unless Map.has_key?(graph, from) and Map.has_key?(graph, to) do
      missing = if Map.has_key?(graph, from), do: to, else: from
      {:error, {:task_not_found, missing}}
    else
      transitive = Graph.transitive_deps(graph)
      from_deps = Map.get(transitive, from, MapSet.new())

      if MapSet.member?(from_deps, to) do
        # to is a dependency of from — find the path
        path = find_path(from, to, graph, [])

        {:ok,
         %{
           type: :tasks,
           data: %{query: :path, from: from, to: to, path: path},
           metadata: metadata("path from #{from} to #{to}")
         }}
      else
        to_deps = Map.get(transitive, to, MapSet.new())

        if MapSet.member?(to_deps, from) do
          path = find_path(to, from, graph, [])

          {:ok,
           %{
             type: :tasks,
             data: %{query: :path, from: to, to: from, path: path, note: "reversed direction"},
             metadata: metadata("path from #{from} to #{to}")
           }}
        else
          {:ok,
           %{
             type: :tasks,
             data: %{
               query: :path,
               from: from,
               to: to,
               path: [],
               note: "no dependency path exists"
             },
             metadata: metadata("path from #{from} to #{to}")
           }}
        end
      end
    end
  end

  # BFS to find shortest dependency path from `from` to `to`
  defp find_path(from, to, graph, _visited) do
    # Simple BFS
    do_bfs(graph, [{[from], MapSet.new([from])}], to)
  end

  defp do_bfs(_graph, [], _target), do: []

  defp do_bfs(graph, [{path, visited} | rest], target) do
    current = hd(path)
    task = Map.get(graph, current)
    deps = (task && task.depends_on) || []

    if target in deps do
      Enum.reverse([target | path])
    else
      new_entries =
        deps
        |> Enum.reject(&MapSet.member?(visited, &1))
        |> Enum.map(fn dep ->
          {[dep | path], MapSet.put(visited, dep)}
        end)

      do_bfs(graph, rest ++ new_entries, target)
    end
  end

  defp load_graph(path) do
    alias Sykli.{Detector, Graph}

    with {:ok, sdk_file} <- Detector.find(path),
         {:ok, json} <- Detector.emit(sdk_file),
         {:ok, graph} <- Graph.parse(json) do
      {:ok, Graph.expand_matrix(graph)}
    end
  end

  defp metadata(query) do
    %{query: query, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}
  end
end
