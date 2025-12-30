defmodule Sykli do
  @moduledoc """
  SYKLI - CI that understands your stack.

  Direct orchestration: detect SDK file, run it, parse JSON, execute tasks.
  """

  alias Sykli.{Detector, Graph, Executor, Cache, RunHistory}

  @doc """
  Run the sykli pipeline.

  Options:
    - filter: function to filter tasks (receives task, returns boolean)
    - save_history: whether to save run history (default: true)
  """
  def run(path \\ ".", opts \\ []) do
    Cache.init()
    filter_fn = Keyword.get(opts, :filter)
    save_history = Keyword.get(opts, :save_history, true)

    with {:ok, sdk_file} <- Detector.find(path),
         {:ok, json} <- Detector.emit(sdk_file),
         {:ok, graph} <- Graph.parse(json) do
      # Expand matrix tasks into individual tasks
      expanded_graph = Graph.expand_matrix(graph)

      # Apply filter if provided
      filtered_graph =
        if filter_fn do
          filter_graph(expanded_graph, filter_fn)
        else
          expanded_graph
        end

      case Graph.topo_sort(filtered_graph) do
        {:ok, order} ->
          result = Executor.run(order, filtered_graph, workdir: path)

          # Save run history if enabled
          if save_history do
            save_run_history(path, result, filtered_graph)
          end

          result

        error ->
          error
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

  # Save run history after execution
  defp save_run_history(path, result, graph) do
    {overall, task_results} = extract_task_results(result, graph)

    # Add likely cause for failed tasks
    task_results_with_cause = add_likely_causes(task_results, path)

    run = %RunHistory.Run{
      id: generate_run_id(),
      timestamp: DateTime.utc_now(),
      git_ref: get_git_ref(path),
      git_branch: get_git_branch(path),
      tasks: task_results_with_cause,
      overall: overall
    }

    RunHistory.save(run, path: path)
  rescue
    # Don't fail the run if history saving fails
    _ -> :ok
  end

  # Add likely cause to failed tasks by correlating git changes with task inputs
  defp add_likely_causes(task_results, path) do
    # Get last good run to compare against
    case RunHistory.load_last_good(path: path) do
      {:ok, last_good} ->
        # Get changed files since last good run
        changed_files = get_changed_files_since(last_good.git_ref, path)

        if MapSet.size(changed_files) > 0 do
          Enum.map(task_results, fn task ->
            if task.status == :failed do
              add_likely_cause_to_task(task, changed_files, path)
            else
              task
            end
          end)
        else
          task_results
        end

      {:error, _} ->
        # No previous good run to compare against
        task_results
    end
  end

  defp add_likely_cause_to_task(task, changed_files, path) do
    # Expand task inputs to actual file paths
    task_input_files =
      (task.inputs || [])
      |> Enum.flat_map(fn pattern -> expand_glob(pattern, path) end)
      |> MapSet.new()

    # Find intersection
    likely_cause = RunHistory.likely_cause(changed_files, task_input_files)

    if MapSet.size(likely_cause) > 0 do
      %{task | likely_cause: MapSet.to_list(likely_cause)}
    else
      task
    end
  end

  defp get_changed_files_since(ref, path) do
    case System.cmd("git", ["diff", "--name-only", ref], cd: path, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp expand_glob(pattern, path) do
    full_pattern = Path.join(path, pattern)

    case Path.wildcard(full_pattern) do
      [] -> []
      files -> Enum.map(files, &Path.relative_to(&1, path))
    end
  end

  defp extract_task_results({:ok, results}, graph) do
    task_results =
      Enum.map(results, fn {name, status, duration_ms} ->
        task = Map.get(graph, name, %{})
        inputs = Map.get(task, :inputs, [])

        %RunHistory.TaskResult{
          name: name,
          status: if(status == :ok, do: :passed, else: :failed),
          duration_ms: duration_ms,
          cached: false,
          inputs: inputs
        }
      end)

    {:passed, task_results}
  end

  defp extract_task_results({:error, results}, graph) when is_list(results) do
    task_results =
      Enum.map(results, fn {name, status, duration_ms} ->
        task = Map.get(graph, name, %{})
        inputs = Map.get(task, :inputs, [])

        {result_status, error} =
          case status do
            :ok -> {:passed, nil}
            {:error, reason} -> {:failed, inspect(reason)}
            _ -> {:failed, inspect(status)}
          end

        %RunHistory.TaskResult{
          name: name,
          status: result_status,
          duration_ms: duration_ms,
          cached: false,
          inputs: inputs,
          error: error
        }
      end)

    {:failed, task_results}
  end

  defp extract_task_results(_, _graph), do: {:failed, []}

  defp generate_run_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp get_git_ref(path) do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: path, stderr_to_stdout: true) do
      {ref, 0} -> String.trim(ref)
      _ -> "unknown"
    end
  end

  defp get_git_branch(path) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {branch, 0} -> String.trim(branch)
      _ -> "unknown"
    end
  end
end
