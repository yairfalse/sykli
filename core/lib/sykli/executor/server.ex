defmodule Sykli.Executor.Server do
  @moduledoc """
  GenServer wrapper around Sykli.Executor that provides:

  - Run tracking with unique IDs
  - Event emission during execution
  - Query current status
  - Cancellation support (future)

  This is the entry point for distributed execution - local runs
  go through this GenServer, which emits events that can be
  forwarded to remote coordinators.
  """

  use GenServer

  alias Sykli.Events
  alias Sykli.RunRegistry

  defstruct [:run_id, :project_path, :status, :tasks, :result, :caller]

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Execute tasks with event emission and run tracking.

  Returns `{:ok, run_id}` immediately. The run executes asynchronously.
  Subscribe to events with `Sykli.Events.subscribe(run_id)` to track progress.

  For synchronous execution, use `execute_sync/4`.
  """
  def execute(project_path, tasks, graph, opts \\ []) do
    GenServer.call(__MODULE__, {:execute, project_path, tasks, graph, opts})
  end

  @doc """
  Execute tasks synchronously, waiting for completion.

  Returns `{:ok, run_id, results}` or `{:error, run_id, reason}`.
  """
  def execute_sync(project_path, tasks, graph, opts \\ []) do
    {:ok, run_id} = execute(project_path, tasks, graph, opts)

    # Subscribe and wait for completion
    Events.subscribe(run_id)

    receive do
      {:run_completed, ^run_id, :ok} ->
        {:ok, run} = RunRegistry.get_run(run_id)
        {:ok, run_id, run.result}

      {:run_completed, ^run_id, {:error, reason}} ->
        {:error, run_id, reason}
    after
      600_000 -> # 10 minute timeout
        {:error, run_id, :timeout}
    end
  end

  @doc """
  Get the current status of a run.
  """
  def get_status(run_id) do
    RunRegistry.get_run(run_id)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{active_runs: %{}}}
  end

  @impl true
  def handle_call({:execute, project_path, tasks, graph, opts}, from, state) do
    # Register the run
    task_names = Enum.map(tasks, & &1.name)
    {:ok, run_id} = RunRegistry.start_run(project_path, task_names)

    # Emit run started event
    Events.run_started(run_id, project_path, task_names)

    # Update status to running
    RunRegistry.update_status(run_id, :running)

    # Spawn execution in a separate process so we don't block
    parent = self()
    spawn_link(fn ->
      result = execute_with_events(run_id, tasks, graph, opts)
      send(parent, {:execution_complete, run_id, result})
    end)

    # Track active run
    run_state = %{
      run_id: run_id,
      project_path: project_path,
      caller: from
    }
    new_state = put_in(state, [:active_runs, run_id], run_state)

    {:reply, {:ok, run_id}, new_state}
  end

  @impl true
  def handle_info({:execution_complete, run_id, result}, state) do
    # Update registry
    completion_result = case result do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :task_failed}
    end
    RunRegistry.complete_run(run_id, completion_result)

    # Emit completion event
    Events.run_completed(run_id, completion_result)

    # Remove from active runs
    new_state = update_in(state, [:active_runs], &Map.delete(&1, run_id))

    {:noreply, new_state}
  end

  ## Private Functions

  # Execute tasks with event emission
  defp execute_with_events(run_id, tasks, graph, opts) do
    workdir = Keyword.get(opts, :workdir, ".")

    # Wrap tasks to emit events
    wrapped_tasks = Enum.map(tasks, fn task ->
      %{task | name: task.name}
    end)

    # Hook into execution by running the existing executor
    # but emitting events for task start/complete
    result = execute_level_by_level(run_id, wrapped_tasks, graph, workdir)

    result
  end

  # Execute tasks level by level, emitting events
  defp execute_level_by_level(run_id, tasks, graph, workdir) do
    # Group by level (same logic as Sykli.Executor)
    levels = group_by_level(tasks, graph)

    run_levels_with_events(run_id, levels, workdir, [])
  end

  defp run_levels_with_events(_run_id, [], _workdir, acc), do: {:ok, Enum.reverse(acc)}

  defp run_levels_with_events(run_id, [level | rest], workdir, acc) do
    level_size = length(level)

    IO.puts("\n#{IO.ANSI.faint()}── Level with #{level_size} task(s)#{if level_size > 1, do: " (parallel)", else: ""} ──#{IO.ANSI.reset()}")

    async_tasks =
      level
      |> Enum.map(fn task ->
        Task.async(fn ->
          # Emit task started
          Events.task_started(run_id, task.name)

          start_time = System.monotonic_time(:millisecond)
          result = run_single_task(task, workdir)
          duration = System.monotonic_time(:millisecond) - start_time

          # Emit task completed
          task_result = if result == :ok, do: :ok, else: {:error, result}
          Events.task_completed(run_id, task.name, task_result)

          {task.name, result, duration}
        end)
      end)

    results = Task.await_many(async_tasks, 300_000)

    failed = Enum.find(results, fn {_name, status, _duration} -> status != :ok end)

    if failed do
      {name, {:error, _reason}, _duration} = failed
      IO.puts("#{IO.ANSI.red()}✗ #{name} failed, stopping#{IO.ANSI.reset()}")
      {:error, Enum.reverse(acc) ++ results}
    else
      run_levels_with_events(run_id, rest, workdir, Enum.reverse(results) ++ acc)
    end
  end

  # Delegate to the existing executor's task running logic
  defp run_single_task(task, workdir) do
    # For now, run shell commands directly
    # Full implementation would call into Sykli.Executor private functions

    command = task.command
    if command do
      now = :calendar.local_time()
      {_, {h, m, s}} = now
      timestamp = :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> to_string()

      IO.puts("#{IO.ANSI.cyan()}▶ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{timestamp} #{command}#{IO.ANSI.reset()}")

      case System.cmd("sh", ["-c", command], cd: workdir, stderr_to_stdout: true) do
        {output, 0} ->
          IO.write("  #{IO.ANSI.faint()}#{output}#{IO.ANSI.reset()}")
          IO.puts("#{IO.ANSI.green()}✓ #{task.name}#{IO.ANSI.reset()}")
          :ok

        {output, code} ->
          IO.write("  #{IO.ANSI.faint()}#{output}#{IO.ANSI.reset()}")
          IO.puts("#{IO.ANSI.red()}✗ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(exit #{code})#{IO.ANSI.reset()}")
          {:error, {:exit_code, code}}
      end
    else
      :ok
    end
  end

  # Group tasks by dependency level (copied from Sykli.Executor)
  defp group_by_level(tasks, graph) do
    task_names = Enum.map(tasks, & &1.name)

    levels =
      task_names
      |> Enum.map(fn name -> {name, calc_level(name, graph, %{})} end)
      |> Map.new()

    tasks
    |> Enum.group_by(fn task -> Map.get(levels, task.name, 0) end)
    |> Enum.sort_by(fn {level, _} -> level end)
    |> Enum.map(fn {_level, level_tasks} -> level_tasks end)
  end

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
end
