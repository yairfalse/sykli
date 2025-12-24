defmodule Sykli.Coordinator do
  @moduledoc """
  Central coordinator that receives execution events from all nodes.

  The Coordinator provides:
  - Real-time view of all active runs across the team
  - Run history for analysis
  - Node health tracking
  - Query interface for dashboards

  ## Running as Coordinator

  Start a coordinator node:

      iex --name coordinator@192.168.1.100 -S mix

  Worker nodes will auto-discover and report to this node.

  ## Queries

      # Get all active runs across all nodes
      Sykli.Coordinator.active_runs()

      # Get run history
      Sykli.Coordinator.run_history(limit: 100)

      # Get connected nodes
      Sykli.Coordinator.connected_nodes()
  """

  use GenServer

  require Logger

  alias Sykli.Events.Event

  @default_history_limit 1000

  # Configurable via Application.get_env(:sykli, :coordinator_history_limit, 1000)
  defp history_limit do
    Application.get_env(:sykli, :coordinator_history_limit, @default_history_limit)
  end

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get all currently active runs across all nodes.
  """
  def active_runs do
    GenServer.call(__MODULE__, :active_runs)
  end

  @doc """
  Get run history.

  Options:
    * `:limit` - Maximum runs to return (default 100)
    * `:node` - Filter by specific node
    * `:status` - Filter by status (:completed, :failed)
  """
  def run_history(opts \\ []) do
    GenServer.call(__MODULE__, {:run_history, opts})
  end

  @doc """
  Get a specific run by ID.
  """
  def get_run(run_id) do
    GenServer.call(__MODULE__, {:get_run, run_id})
  end

  @doc """
  Get list of connected worker nodes.
  """
  def connected_nodes do
    GenServer.call(__MODULE__, :connected_nodes)
  end

  @doc """
  Get coordinator statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Monitor node connections
    :net_kernel.monitor_nodes(true)

    state = %{
      # Active runs: %{run_id => run_info}
      active_runs: %{},
      # Completed runs history (ring buffer)
      history: [],
      history_size: 0,
      # Known nodes: %{node => last_seen}
      nodes: %{},
      # Statistics
      stats: %{
        total_runs: 0,
        successful_runs: 0,
        failed_runs: 0,
        started_at: DateTime.utc_now()
      }
    }

    {:ok, state}
  end

  # Handle Event struct format (v2 with ULIDs) from reporters
  @impl true
  def handle_cast({:event, %Event{} = event}, state) do
    from_node = event.node
    state = update_node_seen(state, from_node)
    state = process_event_struct(event, state)
    {:noreply, state}
  end

  # Handle legacy tuple format for backward compatibility and tests
  @impl true
  def handle_cast({:event, {from_node, event}}, state) do
    # Update node last seen
    state = update_node_seen(state, from_node)

    # Process the event
    state = process_event(from_node, event, state)

    {:noreply, state}
  end

  @impl true
  def handle_call(:active_runs, _from, state) do
    runs = Map.values(state.active_runs)
    {:reply, runs, state}
  end

  @impl true
  def handle_call({:run_history, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    node_filter = Keyword.get(opts, :node)
    status_filter = Keyword.get(opts, :status)

    history =
      state.history
      |> filter_by_node(node_filter)
      |> filter_by_status(status_filter)
      |> Enum.take(limit)

    {:reply, history, state}
  end

  @impl true
  def handle_call({:get_run, run_id}, _from, state) do
    result =
      case Map.get(state.active_runs, run_id) do
        nil ->
          Enum.find(state.history, fn run -> run.id == run_id end)

        run ->
          run
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:connected_nodes, _from, state) do
    nodes =
      state.nodes
      |> Enum.map(fn {node, last_seen} ->
        %{node: node, last_seen: last_seen, connected: Node.ping(node) == :pong}
      end)

    {:reply, nodes, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active_runs: map_size(state.active_runs),
        history_size: state.history_size,
        connected_nodes: length(Node.list())
      })

    {:reply, stats, state}
  end

  # Node monitoring
  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("[Sykli.Coordinator] Node connected: #{node}")
    {:noreply, update_node_seen(state, node)}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("[Sykli.Coordinator] Node disconnected: #{node}")
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  ## Private Functions

  defp process_event(from_node, {:run_started, run_id, project_path, tasks}, state) do
    run = %{
      id: run_id,
      node: from_node,
      project_path: project_path,
      tasks: tasks,
      task_status: %{},
      status: :running,
      started_at: DateTime.utc_now(),
      completed_at: nil
    }

    Logger.info("[Coordinator] Run started: #{run_id} on #{from_node}")

    state
    |> put_in([:active_runs, run_id], run)
    |> update_in([:stats, :total_runs], &(&1 + 1))
  end

  defp process_event(_from_node, {:task_started, run_id, task_name}, state) do
    update_task_status(state, run_id, task_name, :running)
  end

  defp process_event(_from_node, {:task_completed, run_id, task_name, result}, state) do
    status = if result == :ok, do: :completed, else: :failed
    update_task_status(state, run_id, task_name, status)
  end

  defp process_event(_from_node, {:run_completed, run_id, result}, state) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        state

      run ->
        status = if result == :ok, do: :completed, else: :failed
        completed_run = %{run | status: status, completed_at: DateTime.utc_now()}

        Logger.info("[Coordinator] Run completed: #{run_id} (#{status})")

        state
        |> update_in([:active_runs], &Map.delete(&1, run_id))
        |> add_to_history(completed_run)
        |> update_stats(status)
    end
  end

  defp process_event(_from_node, _event, state), do: state

  # Process Event struct format (v2)
  defp process_event_struct(%Event{type: :run_started} = event, state) do
    %{run_id: run_id, node: from_node, data: data} = event

    run = %{
      id: run_id,
      node: from_node,
      project_path: data.project_path,
      tasks: data.tasks,
      task_status: %{},
      status: :running,
      started_at: event.timestamp,
      completed_at: nil
    }

    Logger.info("[Coordinator] Run started: #{run_id} on #{from_node}")

    state
    |> put_in([:active_runs, run_id], run)
    |> update_in([:stats, :total_runs], &(&1 + 1))
  end

  defp process_event_struct(%Event{type: :task_started} = event, state) do
    update_task_status(state, event.run_id, event.data.task_name, :running)
  end

  defp process_event_struct(%Event{type: :task_completed} = event, state) do
    status = if event.data.outcome == :success, do: :completed, else: :failed
    update_task_status(state, event.run_id, event.data.task_name, status)
  end

  defp process_event_struct(%Event{type: :run_completed} = event, state) do
    run_id = event.run_id

    case Map.get(state.active_runs, run_id) do
      nil ->
        state

      run ->
        status = if event.data.outcome == :success, do: :completed, else: :failed
        completed_run = %{run | status: status, completed_at: event.timestamp}

        Logger.info("[Coordinator] Run completed: #{run_id} (#{status})")

        state
        |> update_in([:active_runs], &Map.delete(&1, run_id))
        |> add_to_history(completed_run)
        |> update_stats(status)
    end
  end

  defp process_event_struct(_event, state), do: state

  defp update_task_status(state, run_id, task_name, status) do
    case Map.get(state.active_runs, run_id) do
      nil -> state
      _run -> put_in(state, [:active_runs, run_id, :task_status, task_name], status)
    end
  end

  defp add_to_history(state, run) do
    history = [run | state.history]
    size = state.history_size + 1
    limit = history_limit()

    if size > limit do
      %{state | history: Enum.take(history, limit), history_size: limit}
    else
      %{state | history: history, history_size: size}
    end
  end

  defp update_stats(state, :completed) do
    update_in(state, [:stats, :successful_runs], &(&1 + 1))
  end

  defp update_stats(state, :failed) do
    update_in(state, [:stats, :failed_runs], &(&1 + 1))
  end

  defp update_node_seen(state, node) do
    put_in(state, [:nodes, node], DateTime.utc_now())
  end

  defp filter_by_node(history, nil), do: history
  defp filter_by_node(history, node), do: Enum.filter(history, &(&1.node == node))

  defp filter_by_status(history, nil), do: history
  defp filter_by_status(history, status), do: Enum.filter(history, &(&1.status == status))
end
