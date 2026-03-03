defmodule Sykli.Executor.Server do
  @moduledoc """
  GenServer wrapper around Sykli.Executor that provides:

  - Run tracking with unique IDs
  - Occurrence emission during execution
  - Query current status
  - Cancellation support (future)

  This is the entry point for distributed execution - local runs
  go through this GenServer, which emits occurrences that can be
  forwarded to remote coordinators.
  """

  use GenServer

  alias Sykli.Occurrence
  alias Sykli.Occurrence.PubSub, as: OccPubSub
  alias Sykli.RunRegistry

  defstruct [:run_id, :project_path, :status, :tasks, :result, :caller]

  # Default timeouts (configurable via Application config)
  # 10 minutes for execute_sync
  @default_sync_timeout 600_000
  # 5 minutes per task level
  @default_task_timeout 300_000

  defp sync_timeout do
    Application.get_env(:sykli, :executor_sync_timeout, @default_sync_timeout)
  end

  defp task_timeout do
    Application.get_env(:sykli, :executor_task_timeout, @default_task_timeout)
  end

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Execute tasks with occurrence emission and run tracking.

  Returns `{:ok, run_id}` immediately. The run executes asynchronously.
  Subscribe to occurrences with `Sykli.Occurrence.PubSub.subscribe(run_id)`.

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
    # Subscribe BEFORE execute to avoid race
    OccPubSub.subscribe(:all)

    {:ok, run_id} = execute(project_path, tasks, graph, opts)

    result =
      receive do
        %Occurrence{type: "ci.run.passed", run_id: ^run_id} ->
          {:ok, run} = RunRegistry.get_run(run_id)
          {:ok, run_id, run.result}

        %Occurrence{type: "ci.run.failed", run_id: ^run_id} ->
          {:error, run_id, :task_failed}
      after
        sync_timeout() ->
          {:error, run_id, :timeout}
      end

    OccPubSub.unsubscribe(:all)
    result
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

    # Emit run started occurrence
    OccPubSub.run_started(run_id, project_path, task_names)

    # Update status to running
    RunRegistry.update_status(run_id, :running)

    # Spawn execution as a linked Task so crashes propagate to the GenServer
    parent = self()

    Task.start_link(fn ->
      result =
        try do
          execute_with_events(run_id, tasks, graph, opts)
        catch
          kind, reason ->
            {:error, {:crashed, kind, reason}}
        end

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
    completion_result =
      case result do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :task_failed}
      end

    RunRegistry.complete_run(run_id, completion_result)

    # Emit completion occurrence
    OccPubSub.run_completed(run_id, completion_result)

    # Remove from active runs
    new_state = update_in(state, [:active_runs], &Map.delete(&1, run_id))

    {:noreply, new_state}
  end

  ## Private Functions

  defp execute_with_events(run_id, tasks, graph, opts) do
    workdir = Keyword.get(opts, :workdir, ".")
    timeout = Keyword.get(opts, :timeout, task_timeout())
    execute_level_by_level(run_id, tasks, graph, workdir, timeout)
  end

  defp execute_level_by_level(run_id, tasks, graph, workdir, timeout) do
    levels = group_by_level(tasks, graph)
    run_levels_with_events(run_id, levels, workdir, timeout, [])
  end

  defp run_levels_with_events(_run_id, [], _workdir, _timeout, acc), do: {:ok, Enum.reverse(acc)}

  defp run_levels_with_events(run_id, [level | rest], workdir, timeout, acc) do
    level_size = length(level)

    IO.puts(
      "\n#{IO.ANSI.faint()}── Level with #{level_size} task(s)#{if level_size > 1, do: " (parallel)", else: ""} ──#{IO.ANSI.reset()}"
    )

    async_tasks =
      level
      |> Enum.map(fn task ->
        Task.async(fn ->
          OccPubSub.task_started(run_id, task.name)

          start_time = System.monotonic_time(:millisecond)
          result = run_single_task(task, workdir)
          duration = System.monotonic_time(:millisecond) - start_time

          task_result = if result == :ok, do: :ok, else: {:error, result}
          OccPubSub.task_completed(run_id, task.name, task_result)

          {task.name, result, duration}
        end)
      end)

    results = Task.await_many(async_tasks, timeout)

    failed = Enum.find(results, fn {_name, status, _duration} -> status != :ok end)

    if failed do
      {name, {:error, _reason}, _duration} = failed
      IO.puts("#{IO.ANSI.red()}✗ #{name} failed, stopping#{IO.ANSI.reset()}")
      {:error, Enum.reverse(acc) ++ results}
    else
      run_levels_with_events(run_id, rest, workdir, timeout, Enum.reverse(results) ++ acc)
    end
  end

  defp run_single_task(task, workdir) do
    command = task.command

    if command do
      now = :calendar.local_time()
      {_, {h, m, s}} = now
      timestamp = :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> to_string()

      IO.puts(
        "#{IO.ANSI.cyan()}▶ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{timestamp} #{command}#{IO.ANSI.reset()}"
      )

      case System.cmd("sh", ["-c", command],
             cd: workdir,
             stderr_to_stdout: true,
             env: [{"__BURRITO_BIN_PATH", nil}]
           ) do
        {output, 0} ->
          IO.write("  #{IO.ANSI.faint()}#{output}#{IO.ANSI.reset()}")
          IO.puts("#{IO.ANSI.green()}✓ #{task.name}#{IO.ANSI.reset()}")
          :ok

        {output, code} ->
          IO.write("  #{IO.ANSI.faint()}#{output}#{IO.ANSI.reset()}")

          IO.puts(
            "#{IO.ANSI.red()}✗ #{task.name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(exit #{code})#{IO.ANSI.reset()}"
          )

          {:error, {:exit_code, code}}
      end
    else
      :ok
    end
  end

  defp group_by_level(tasks, graph) do
    Sykli.Executor.group_by_level(tasks, graph)
  end
end
