defmodule Sykli do
  @moduledoc """
  SYKLI - CI that understands your stack.

  Direct orchestration: detect SDK file, run it, parse JSON, execute tasks.
  """

  alias Sykli.{Detector, Graph, Executor, Cache}

  @doc """
  Run the sykli pipeline.

  Options:
    - filter: function to filter tasks (receives task, returns boolean)
  """
  def run(path \\ ".", opts \\ []) do
    Cache.init()
    filter_fn = Keyword.get(opts, :filter)

    with {:ok, sdk_file} <- Detector.find(path),
         {:ok, json} <- Detector.emit(sdk_file),
         {:ok, graph} <- Graph.parse(json) do
      # Expand matrix tasks into individual tasks
      expanded_graph = Graph.expand_matrix(graph)

      # Apply filter if provided
      filtered_graph = if filter_fn do
        filter_graph(expanded_graph, filter_fn)
      else
        expanded_graph
      end

      case Graph.topo_sort(filtered_graph) do
        {:ok, order} -> Executor.run(order, filtered_graph, workdir: path)
        error -> error
      end
    else
      {:error, :no_sdk_file} ->
        IO.puts(:stderr, "\e[31m✗ No sykli file found\e[0m")
        IO.puts(:stderr, "")
        IO.puts(:stderr, "\e[36mQuick start — create sykli.go:\e[0m")
        IO.puts(:stderr, "")
        IO.puts(:stderr, "    package main")
        IO.puts(:stderr, "")
        IO.puts(:stderr, "    import sykli \"github.com/yairfalse/sykli/sdk/go\"")
        IO.puts(:stderr, "")
        IO.puts(:stderr, "    func main() {")
        IO.puts(:stderr, "        s := sykli.New()")
        IO.puts(:stderr, "        s.Task(\"hello\").Run(\"echo 'Hello from sykli!'\")")
        IO.puts(:stderr, "        s.Emit()")
        IO.puts(:stderr, "    }")
        IO.puts(:stderr, "")
        IO.puts(:stderr, "Then run: \e[32msykli\e[0m")
        IO.puts(:stderr, "")
        IO.puts(:stderr, "Docs: \e[34mhttps://github.com/yairfalse/sykli\e[0m")
        {:error, :no_sdk_file}

      {:error, {:missing_tool, tool, hint}} ->
        IO.puts(:stderr, "\e[31m✗ '#{tool}' is not installed\e[0m")
        IO.puts(:stderr, "  #{hint}")
        {:error, {:missing_tool, tool}}

      {:error, {:go_failed, output}} ->
        IO.puts(:stderr, "\e[31m✗ Go SDK failed\e[0m")
        IO.puts(:stderr, output)
        {:error, :go_failed}

      {:error, {:rust_failed, output}} ->
        IO.puts(:stderr, "\e[31m✗ Rust SDK failed\e[0m")
        IO.puts(:stderr, output)
        {:error, :rust_failed}

      {:error, {:rust_cargo_failed, output}} ->
        IO.puts(:stderr, "\e[31m✗ Cargo build failed\e[0m")
        IO.puts(:stderr, output)
        {:error, :cargo_failed}

      {:error, {:elixir_failed, output}} ->
        IO.puts(:stderr, "\e[31m✗ Elixir SDK failed\e[0m")
        IO.puts(:stderr, output)
        {:error, :elixir_failed}

      {:error, {:json_parse_error, error}} ->
        IO.puts(:stderr, "\e[31m✗ Failed to parse task graph\e[0m")
        IO.puts(:stderr, "  #{inspect(error)}")
        {:error, :json_parse_error}

      error ->
        IO.puts(:stderr, "\e[31m✗ Error: #{inspect(error)}\e[0m")
        error
    end
  end

  # Filter graph (map of name => task) to only include matching tasks + their dependencies
  defp filter_graph(graph, filter_fn) when is_map(graph) do
    # Graph is a map: %{name => task}
    all_tasks = Map.values(graph)

    # Get tasks that match the filter
    matching_names =
      all_tasks
      |> Enum.filter(filter_fn)
      |> Enum.map(& &1.name)
      |> MapSet.new()

    # Add all upstream dependencies (transitively)
    all_needed = add_dependencies(matching_names, graph)

    # Filter to only those needed
    Map.filter(graph, fn {name, _task} ->
      MapSet.member?(all_needed, name)
    end)
  end

  # Add all dependencies transitively (upstream tasks)
  # graph is a map of name => task
  defp add_dependencies(task_names, graph) when is_map(graph) do
    do_add_deps(MapSet.to_list(task_names), task_names, graph)
  end

  defp do_add_deps([], result, _task_map), do: result

  defp do_add_deps([name | rest], result, task_map) do
    task = Map.get(task_map, name)
    deps = (task && task.depends_on) || []

    new_deps = Enum.reject(deps, &MapSet.member?(result, &1))
    new_result = Enum.reduce(new_deps, result, &MapSet.put(&2, &1))

    do_add_deps(rest ++ new_deps, new_result, task_map)
  end
end
