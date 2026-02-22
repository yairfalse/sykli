defmodule Sykli.Reporter do
  @moduledoc """
  Forwards local occurrences to the coordinator node.

  The Reporter subscribes to all local occurrences and forwards them
  to the Coordinator GenServer on the coordinator node. Occurrences
  are buffered if the coordinator is temporarily unavailable.

  ## Coordinator Discovery

  The Reporter looks for a coordinator in this order:
  1. Configured coordinator node (via `configure/1`)
  2. Auto-discovered via libcluster (node named `coordinator@...`)
  3. No forwarding (occurrences stay local)
  """

  use GenServer

  require Logger

  alias Sykli.Occurrence

  @default_buffer_limit 1000

  defp buffer_limit do
    Application.get_env(:sykli, :reporter_buffer_limit, @default_buffer_limit)
  end

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Configure the coordinator node to report to."
  def configure(coordinator_node) when is_binary(coordinator_node) do
    configure(String.to_atom(coordinator_node))
  end

  def configure(coordinator_node) when is_atom(coordinator_node) do
    GenServer.call(__MODULE__, {:configure, coordinator_node})
  end

  @doc "Get current reporter status."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Check if we're connected to a coordinator."
  def connected? do
    case status() do
      %{connected: true} -> true
      _ -> false
    end
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Subscribe to all occurrences
    Sykli.Occurrence.PubSub.subscribe(:all)

    coordinator = discover_coordinator()

    state = %{
      coordinator: coordinator,
      connected: coordinator != nil && Node.ping(coordinator) == :pong,
      buffer: [],
      buffer_size: 0
    }

    :net_kernel.monitor_nodes(true)

    {:ok, state}
  end

  @impl true
  def handle_call({:configure, coordinator_node}, _from, state) do
    connected = Node.ping(coordinator_node) == :pong
    new_state = %{state | coordinator: coordinator_node, connected: connected}
    new_state = if connected, do: flush_buffer(new_state), else: new_state
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      coordinator: state.coordinator,
      connected: state.connected,
      buffered: state.buffer_size
    }

    {:reply, status, state}
  end

  # Handle Occurrence structs — forward important ones, skip output
  @impl true
  def handle_info(%Occurrence{type: "ci.task.output"} = occ, state) do
    # Don't buffer output occurrences — too much data
    if state.connected && state.coordinator do
      send_to_coordinator(state.coordinator, occ)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(%Occurrence{type: type} = occ, state)
      when type in [
             "ci.run.started",
             "ci.task.started",
             "ci.task.completed",
             "ci.run.passed",
             "ci.run.failed"
           ] do
    {:noreply, forward_occurrence(occ, state)}
  end

  # Gate events — forward without buffering
  @impl true
  def handle_info(%Occurrence{type: "ci.gate." <> _} = occ, state) do
    if state.connected && state.coordinator do
      send_to_coordinator(state.coordinator, occ)
    end

    {:noreply, state}
  end

  # Node monitoring
  @impl true
  def handle_info({:nodeup, node}, state) do
    if node == state.coordinator do
      Logger.info("[Sykli.Reporter] Connected to coordinator #{node}")
      new_state = %{state | connected: true}
      {:noreply, flush_buffer(new_state)}
    else
      if coordinator_node?(node) && state.coordinator == nil do
        Logger.info("[Sykli.Reporter] Discovered coordinator #{node}")
        new_state = %{state | coordinator: node, connected: true}
        {:noreply, flush_buffer(new_state)}
      else
        {:noreply, state}
      end
    end
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    if node == state.coordinator do
      Logger.warning("[Sykli.Reporter] Lost connection to coordinator #{node}")
      {:noreply, %{state | connected: false}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  ## Private Functions

  defp forward_occurrence(occ, %{connected: true, coordinator: coord} = state)
       when coord != nil do
    send_to_coordinator(coord, occ)
    state
  end

  defp forward_occurrence(occ, state) do
    buffer_occurrence(occ, state)
  end

  defp send_to_coordinator(coordinator, %Occurrence{} = occ) do
    GenServer.cast({Sykli.Coordinator, coordinator}, {:occurrence, occ})
  end

  defp buffer_occurrence(occ, %{buffer_size: size} = state) do
    limit = buffer_limit()

    if size >= limit do
      buffer = Enum.take(state.buffer, limit - 1)
      %{state | buffer: [occ | buffer], buffer_size: limit}
    else
      %{state | buffer: [occ | state.buffer], buffer_size: size + 1}
    end
  end

  defp flush_buffer(%{buffer: [], coordinator: _} = state), do: state

  defp flush_buffer(%{buffer: buffer, coordinator: coord} = state) when coord != nil do
    buffer
    |> Enum.reverse()
    |> Enum.each(&send_to_coordinator(coord, &1))

    %{state | buffer: [], buffer_size: 0}
  end

  defp flush_buffer(state), do: state

  defp discover_coordinator do
    Node.list()
    |> Enum.find(&coordinator_node?/1)
  end

  defp coordinator_node?(node) do
    node
    |> Atom.to_string()
    |> String.starts_with?("coordinator@")
  end
end
