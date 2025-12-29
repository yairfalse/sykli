defmodule Sykli.Watch do
  @moduledoc """
  File watcher that re-runs affected tasks on changes.

  Uses file_system to watch directories and triggers delta runs
  with debouncing to avoid excessive rebuilds.
  """

  use GenServer
  require Logger

  @debounce_ms 200

  defstruct [:path, :watcher_pid, :pending_files, :timer_ref, :from_ref]

  # ----- PUBLIC API -----

  @doc """
  Start watching a directory and run delta on changes.
  Blocks until stopped with Ctrl+C.
  """
  def start(path, opts \\ []) do
    from_ref = Keyword.get(opts, :from, "HEAD")

    case GenServer.start_link(__MODULE__, {path, from_ref}, name: __MODULE__) do
      {:ok, pid} ->
        # Block until stopped
        ref = Process.monitor(pid)
        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            if reason == :normal, do: :ok, else: {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stop watching.
  """
  def stop do
    GenServer.stop(__MODULE__, :normal)
  catch
    :exit, _ -> :ok
  end

  # ----- GENSERVER CALLBACKS -----

  @impl true
  def init({path, from_ref}) do
    abs_path = Path.expand(path)

    # Start file watcher
    {:ok, watcher_pid} = FileSystem.start_link(dirs: [abs_path])
    FileSystem.subscribe(watcher_pid)

    IO.puts("#{IO.ANSI.cyan()}Watching #{abs_path}#{IO.ANSI.reset()}")
    IO.puts("#{IO.ANSI.faint()}Press Ctrl+C to stop#{IO.ANSI.reset()}\n")

    # Run initial delta to show current state
    run_delta(abs_path, from_ref, [])

    state = %__MODULE__{
      path: abs_path,
      watcher_pid: watcher_pid,
      pending_files: MapSet.new(),
      timer_ref: nil,
      from_ref: from_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {file_path, _events}}, state) do
    # Ignore certain files/directories
    if should_ignore?(file_path) do
      {:noreply, state}
    else
      # Add to pending files
      new_pending = MapSet.put(state.pending_files, file_path)

      # Cancel existing timer and flush any pending :run_delta message
      if state.timer_ref do
        Process.cancel_timer(state.timer_ref, info: false)
        receive do
          :run_delta -> :ok
        after
          0 -> :ok
        end
      end

      # Set new debounce timer
      timer_ref = Process.send_after(self(), :run_delta, @debounce_ms)

      {:noreply, %{state | pending_files: new_pending, timer_ref: timer_ref}}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:run_delta, state) do
    files = MapSet.to_list(state.pending_files)
    run_delta(state.path, state.from_ref, files)

    {:noreply, %{state | pending_files: MapSet.new(), timer_ref: nil}}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # ----- PRIVATE -----

  defp should_ignore?(path) do
    basename = Path.basename(path)
    dirname = Path.dirname(path)

    # Ignore hidden files, build artifacts, etc.
    String.starts_with?(basename, ".") or
    String.contains?(dirname, "/_build/") or
    String.contains?(dirname, "/deps/") or
    String.contains?(dirname, "/node_modules/") or
    String.contains?(dirname, "/.git/") or
    String.contains?(dirname, "/target/") or
    String.ends_with?(basename, ".beam") or
    String.ends_with?(basename, ".pyc")
  end

  defp run_delta(path, from_ref, changed_files) do
    # Show changed files if any
    if changed_files != [] do
      IO.puts("\n#{IO.ANSI.cyan()}Changed:#{IO.ANSI.reset()}")
      changed_files
      |> Enum.take(5)
      |> Enum.each(fn f ->
        rel_path = Path.relative_to(f, path)
        IO.puts("  #{IO.ANSI.faint()}#{rel_path}#{IO.ANSI.reset()}")
      end)
      if length(changed_files) > 5 do
        IO.puts("  #{IO.ANSI.faint()}+#{length(changed_files) - 5} more#{IO.ANSI.reset()}")
      end
      IO.puts("")
    end

    # Get affected tasks
    case get_task_graph(path) do
      {:ok, tasks} ->
        case Sykli.Delta.affected_tasks_detailed(tasks, from: from_ref, path: path) do
          {:ok, []} ->
            IO.puts("#{IO.ANSI.green()}No tasks affected#{IO.ANSI.reset()}\n")

          {:ok, affected} ->
            IO.puts("#{IO.ANSI.yellow()}Affected tasks:#{IO.ANSI.reset()}")
            Enum.each(affected, fn task ->
              IO.puts("  #{task.name}")
            end)
            IO.puts("")

            # Run affected tasks
            run_affected(path, affected)

          {:error, reason} ->
            IO.puts("#{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}\n")
        end

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}Error loading tasks: #{inspect(reason)}#{IO.ANSI.reset()}\n")
    end
  end

  defp get_task_graph(path) do
    with {:ok, sdk} <- Sykli.Detector.find(path),
         {:ok, json} <- Sykli.Detector.emit(sdk),
         {:ok, data} <- Jason.decode(json) do
      tasks = parse_tasks(data)
      {:ok, tasks}
    end
  end

  defp parse_tasks(data) do
    (data["tasks"] || [])
    |> Enum.map(fn task ->
      %{
        name: task["name"],
        depends_on: task["depends_on"] || [],
        inputs: task["inputs"]
      }
    end)
  end

  defp run_affected(path, affected) do
    affected_names = Enum.map(affected, & &1.name)
    affected_set = MapSet.new(affected_names)

    start_time = System.monotonic_time(:millisecond)

    case Sykli.run(path, filter: fn task -> MapSet.member?(affected_set, task.name) end) do
      {:ok, _results} ->
        duration = System.monotonic_time(:millisecond) - start_time
        IO.puts("#{IO.ANSI.green()}Done in #{format_duration(duration)}#{IO.ANSI.reset()}\n")

      {:error, _} ->
        IO.puts("#{IO.ANSI.red()}Failed#{IO.ANSI.reset()}\n")
    end
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
