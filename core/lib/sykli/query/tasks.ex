defmodule Sykli.Query.Tasks do
  @moduledoc """
  Task structure queries: critical tasks, dependencies, details.
  """

  alias Sykli.Graph.Task
  alias Sykli.{Context, Explain}

  @spec execute(atom(), String.t() | nil, String.t()) :: {:ok, map()} | {:error, term()}
  def execute(query_type, target, path) do
    with {:ok, graph} <- load_graph(path) do
      case query_type do
        :critical -> critical_tasks(graph)
        :deps -> dependencies_of(target, graph)
        :dependents -> dependents_of(target, graph)
        :details -> task_details(target, graph)
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

    {:ok, %{
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

        {:ok, %{
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

      {:ok, %{
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
        {:ok, %{
          type: :tasks,
          data: %{query: :details, task: Context.task_to_map(task)},
          metadata: metadata("task #{task_name}")
        }}
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
