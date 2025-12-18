defmodule Sykli.Reporter do
  @moduledoc """
  Forwards local execution events to the coordinator node.

  The Reporter subscribes to all local events and forwards them
  to the Coordinator GenServer on the coordinator node. Events
  are buffered if the coordinator is temporarily unavailable.

  ## Coordinator Discovery

  The Reporter looks for a coordinator in this order:
  1. Configured coordinator node (via `configure/1`)
  2. Auto-discovered via libcluster (node named `coordinator@...`)
  3. No forwarding (events stay local)

  ## Example

      # Configure a specific coordinator
      Sykli.Reporter.configure("coordinator@192.168.1.100")

      # Check status
      Sykli.Reporter.status()
      # => %{coordinator: "coordinator@...", connected: true, buffered: 0}
  """

  use GenServer

  require Logger

  @buffer_limit 1000

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Configure the coordinator node to report to.
  """
  def configure(coordinator_node) when is_binary(coordinator_node) do
    configure(String.to_atom(coordinator_node))
  end

  def configure(coordinator_node) when is_atom(coordinator_node) do
    GenServer.call(__MODULE__, {:configure, coordinator_node})
  end

  @doc """
  Get current reporter status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Check if we're connected to a coordinator.
  """
  def connected? do
    case status() do
      %{connected: true} -> true
      _ -> false
    end
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Subscribe to all events
    Sykli.Events.subscribe(:all)

    # Try to discover coordinator on startup
    coordinator = discover_coordinator()

    state = %{
      coordinator: coordinator,
      connected: coordinator != nil && Node.ping(coordinator) == :pong,
      buffer: [],
      buffer_size: 0
    }

    # Monitor node connections
    :net_kernel.monitor_nodes(true)

    {:ok, state}
  end

  @impl true
  def handle_call({:configure, coordinator_node}, _from, state) do
    connected = Node.ping(coordinator_node) == :pong
    new_state = %{state | coordinator: coordinator_node, connected: connected}

    # If we just connected, flush buffer
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

  # Handle execution events
  @impl true
  def handle_info({event_type, _run_id, _} = event, state)
      when event_type in [:run_started, :task_started, :task_completed, :run_completed] do
    {:noreply, forward_event(event, state)}
  end

  @impl true
  def handle_info({:run_started, _run_id, _, _} = event, state) do
    {:noreply, forward_event(event, state)}
  end

  @impl true
  def handle_info({:task_output, _run_id, _, _} = event, state) do
    # Don't buffer output events - too much data
    # Only forward if connected
    if state.connected && state.coordinator do
      send_to_coordinator(state.coordinator, event)
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:task_completed, _run_id, _, _} = event, state) do
    {:noreply, forward_event(event, state)}
  end

  # Node monitoring
  @impl true
  def handle_info({:nodeup, node}, state) do
    if node == state.coordinator do
      Logger.info("[Sykli.Reporter] Connected to coordinator #{node}")
      new_state = %{state | connected: true}
      {:noreply, flush_buffer(new_state)}
    else
      # Check if this might be a coordinator
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

  defp forward_event(event, %{connected: true, coordinator: coord} = state) when coord != nil do
    send_to_coordinator(coord, event)
    state
  end

  defp forward_event(event, state) do
    # Buffer event if not connected
    buffer_event(event, state)
  end

  defp send_to_coordinator(coordinator, event) do
    # Add node info to event
    event_with_node = {node(), event}

    # Send to Coordinator GenServer on the coordinator node
    GenServer.cast({Sykli.Coordinator, coordinator}, {:event, event_with_node})
  end

  defp buffer_event(event, %{buffer_size: size} = state) when size >= @buffer_limit do
    # Drop oldest events when buffer is full
    buffer = Enum.take(state.buffer, @buffer_limit - 1)
    %{state | buffer: [event | buffer], buffer_size: @buffer_limit}
  end

  defp buffer_event(event, state) do
    %{state | buffer: [event | state.buffer], buffer_size: state.buffer_size + 1}
  end

  defp flush_buffer(%{buffer: [], coordinator: _} = state), do: state

  defp flush_buffer(%{buffer: buffer, coordinator: coord} = state) when coord != nil do
    # Send buffered events in order (oldest first)
    buffer
    |> Enum.reverse()
    |> Enum.each(&send_to_coordinator(coord, &1))

    %{state | buffer: [], buffer_size: 0}
  end

  defp flush_buffer(state), do: state

  defp discover_coordinator do
    # Look for a node named "coordinator@..."
    Node.list()
    |> Enum.find(&coordinator_node?/1)
  end

  defp coordinator_node?(node) do
    node
    |> Atom.to_string()
    |> String.starts_with?("coordinator@")
  end
end
