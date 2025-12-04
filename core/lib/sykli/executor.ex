defmodule Sykli.Executor do
  @moduledoc """
  Executes tasks with parallelism for independent tasks.
  """

  # Note: we DON'T alias Sykli.Graph.Task because it shadows Elixir's Task module
  # Use full path: %Sykli.Graph.Task{}

  def run(tasks, graph, opts \\ []) do
    workdir = Keyword.get(opts, :workdir, ".")

    # Group tasks by "level" - tasks at same level can run in parallel
    levels = group_by_level(tasks, graph)

    # Execute level by level
    run_levels(levels, workdir)
  end

  # ----- GROUPING TASKS BY DEPENDENCY LEVEL -----

  # Tasks with no deps = level 0
  # Tasks depending only on level 0 = level 1
  # etc.

  defp group_by_level(tasks, graph) do
    # Start with all tasks at level 0
    task_names = Enum.map(tasks, & &1.name)

    # Calculate level for each task
    levels =
      task_names
      |> Enum.map(fn name -> {name, calc_level(name, graph, %{})} end)
      |> Map.new()

    # Group by level, return list of lists
    tasks
    |> Enum.group_by(fn task -> Map.get(levels, task.name, 0) end)
    |> Enum.sort_by(fn {level, _} -> level end)
    |> Enum.map(fn {_level, level_tasks} -> level_tasks end)
  end

  # Recursive level calculation:
  # level = max(level of all dependencies) + 1
  # base case: no deps = level 0
  defp calc_level(name, graph, cache) do
    if Map.has_key?(cache, name) do
      cache[name]
    else
      task = Map.get(graph, name)
      deps = if task, do: task.depends_on, else: []

      if deps == [] do
        0
      else
        deps
        |> Enum.map(&calc_level(&1, graph, cache))
        |> Enum.max()
        |> Kernel.+(1)
      end
    end
  end

  # ----- EXECUTING LEVELS -----

  defp run_levels([], _workdir), do: {:ok, []}

  defp run_levels([level | rest], workdir) do
    IO.puts("\n#{IO.ANSI.faint()}── Level with #{length(level)} task(s) ──#{IO.ANSI.reset()}")

    # THIS IS THE PARALLEL BIT!
    # Task.async spawns a new process for each task
    # Task.await_many waits for all to complete

    async_tasks =
      level
      |> Enum.map(fn task ->
        Task.async(fn ->
          {task.name, run_single(task, workdir)}
        end)
      end)

    # Wait for all tasks in this level (30 second timeout per task)
    results = Task.await_many(async_tasks, 30_000)

    # Check if any failed
    failed = Enum.find(results, fn {_name, status} -> status != :ok end)

    if failed do
      {name, {:error, _reason}} = failed
      IO.puts("#{IO.ANSI.red()}✗ #{name} failed, stopping#{IO.ANSI.reset()}")
      {:error, results}
    else
      # Continue to next level
      case run_levels(rest, workdir) do
        {:ok, rest_results} -> {:ok, results ++ rest_results}
        error -> error
      end
    end
  end

  # ----- RUNNING A SINGLE TASK -----

  defp run_single(%Sykli.Graph.Task{name: name, command: command}, workdir) do
    IO.puts("#{IO.ANSI.cyan()}▶ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{command}#{IO.ANSI.reset()}")

    # Post pending status to GitHub
    maybe_github_status(name, "pending")

    # Run through shell to support env vars, pipes, etc.
    case System.cmd("sh", ["-c", command], cd: workdir, stderr_to_stdout: true) do
      {_output, 0} ->
        IO.puts("#{IO.ANSI.green()}✓ #{name}#{IO.ANSI.reset()}")
        maybe_github_status(name, "success")
        :ok

      {output, code} ->
        IO.puts("#{IO.ANSI.red()}✗ #{name} (exit #{code})#{IO.ANSI.reset()}")
        IO.puts(output)
        maybe_github_status(name, "failure")
        {:error, {:exit_code, code}}
    end
  end

  defp maybe_github_status(task_name, state) do
    if Sykli.GitHub.enabled?() do
      Sykli.GitHub.update_status(task_name, state)
    end
  end
end
