defmodule Sykli.Graph do
  @moduledoc """
  Parses task graph JSON and performs topological sort.
  """

  defmodule Task do
    defstruct [:name, :command, :inputs, :depends_on, :condition]
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
      depends_on: (map["depends_on"] || []) |> Enum.uniq(),  # dedupe!
      condition: map["condition"]
    }
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
        Enum.reduce(task.depends_on, acc, fn dep, acc2 ->
          Map.update(acc2, dep, 0, & &1)
        end)
      end)

    in_degree =
      Enum.reduce(graph, in_degree, fn {_name, task}, acc ->
        Enum.reduce(task.depends_on, acc, fn _dep, acc2 ->
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

  defp do_topo_sort([], in_degree, _graph, result) do
    remaining = Enum.filter(in_degree, fn {_, deg} -> deg > 0 end)

    if remaining == [] do
      {:ok, Enum.reverse(result)}
    else
      {:error, :cycle_detected}
    end
  end

  defp do_topo_sort([current | rest], in_degree, graph, result) do
    task = Map.get(graph, current)

    # Find tasks that depend on current
    dependents =
      graph
      |> Enum.filter(fn {_name, t} -> current in t.depends_on end)
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
end
