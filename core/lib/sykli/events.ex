defmodule Sykli.Events do
  @moduledoc """
  Pub/sub event system for sykli execution events.

  Events are broadcast locally and can be subscribed to by any process.
  When nodes are connected, PubSub automatically distributes events
  across the cluster.

  ## Event Formats

  Events are emitted in two formats for compatibility:

  1. **Event struct** (v2) - `%Sykli.Events.Event{}` with ULID, timestamp, typed data
  2. **Tuple** (legacy) - `{:event_type, run_id, ...}` for backward compatibility

  Subscribe to the format you need:
  - `subscribe(run_id)` - Event structs (recommended)
  - `subscribe_legacy(run_id)` - Tuples (backward compatible)

  ## Event Types

    * `:run_started` - A run has begun
    * `:task_started` - A task is starting execution
    * `:task_output` - Output from a running task
    * `:task_completed` - Task finished
    * `:run_completed` - All tasks done

  ## Typed Event Data

  Event data is now typed using dedicated structs:
    * `Sykli.Events.RunStarted` - run_started event data
    * `Sykli.Events.RunCompleted` - run_completed event data
    * `Sykli.Events.TaskStarted` - task_started event data
    * `Sykli.Events.TaskCompleted` - task_completed event data
    * `Sykli.Events.TaskOutput` - task_output event data

  ## Example

      # Subscribe to events (v2 format)
      Sykli.Events.subscribe(run_id)

      receive do
        %Sykli.Events.Event{type: :task_completed, data: %TaskCompleted{}} = event ->
          IO.puts("Task \#{event.data.task_name} completed!")
      end

      # Or legacy format
      Sykli.Events.subscribe_legacy(run_id)

      receive do
        {:task_completed, ^run_id, task_name, :ok} ->
          IO.puts("Task \#{task_name} completed!")
      end
  """

  alias Sykli.Events.Event
  alias Sykli.Events.GateWaiting
  alias Sykli.Events.GateResolved
  alias Sykli.Events.RunStarted
  alias Sykli.Events.RunCompleted
  alias Sykli.Events.TaskStarted
  alias Sykli.Events.TaskCompleted
  alias Sykli.Events.TaskOutput

  @pubsub Sykli.PubSub

  @doc """
  Subscribe to events (Event struct format) for a specific run or all runs.
  """
  def subscribe(run_id \\ :all) do
    Phoenix.PubSub.subscribe(@pubsub, topic(run_id))
  end

  @doc """
  Subscribe to legacy tuple events for backward compatibility.
  """
  def subscribe_legacy(run_id \\ :all) do
    Phoenix.PubSub.subscribe(@pubsub, legacy_topic(run_id))
  end

  @doc """
  Unsubscribe from events.
  """
  def unsubscribe(run_id \\ :all) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(run_id))
    Phoenix.PubSub.unsubscribe(@pubsub, legacy_topic(run_id))
  end

  @doc """
  Broadcast a run_started event. Returns the Event struct.
  """
  def run_started(run_id, project_path, tasks) do
    data = RunStarted.new(project_path, tasks)
    event = Event.new(:run_started, run_id, data)

    broadcast(event)
    broadcast_legacy({:run_started, run_id, project_path, tasks}, run_id)
    event
  end

  @doc """
  Broadcast a task_started event. Returns the Event struct.
  """
  def task_started(run_id, task_name) do
    data = TaskStarted.new(task_name)
    event = Event.new(:task_started, run_id, data)

    broadcast(event)
    broadcast_legacy({:task_started, run_id, task_name}, run_id)
    event
  end

  @doc """
  Broadcast task output. Returns the Event struct.
  """
  def task_output(run_id, task_name, output) do
    data = TaskOutput.new(task_name, output)
    event = Event.new(:task_output, run_id, data)

    broadcast(event)
    broadcast_legacy({:task_output, run_id, task_name, output}, run_id)
    event
  end

  @doc """
  Broadcast a task_completed event. Returns the Event struct.
  """
  def task_completed(run_id, task_name, result) do
    data = TaskCompleted.from_result(task_name, result, nil)
    event = Event.new(:task_completed, run_id, data)

    broadcast(event)
    broadcast_legacy({:task_completed, run_id, task_name, result}, run_id)
    event
  end

  @doc """
  Broadcast a run_completed event. Returns the Event struct.
  """
  def run_completed(run_id, result) do
    data = RunCompleted.from_result(result)
    event = Event.new(:run_completed, run_id, data)

    broadcast(event)
    broadcast_legacy({:run_completed, run_id, result}, run_id)
    event
  end

  @doc """
  Broadcast a gate_waiting event. Returns the Event struct.
  """
  def gate_waiting(run_id, gate_name, strategy, message, timeout) do
    data = GateWaiting.new(gate_name, strategy, message, timeout)
    event = Event.new(:gate_waiting, run_id, data)

    broadcast(event)
    event
  end

  @doc """
  Broadcast a gate_resolved event. Returns the Event struct.
  """
  def gate_resolved(run_id, gate_name, outcome, approver, duration_ms) do
    data = GateResolved.new(gate_name, outcome, approver, duration_ms)
    event = Event.new(:gate_resolved, run_id, data)

    broadcast(event)
    event
  end

  @doc """
  Create an event struct without broadcasting (for manual emission).
  """
  def create(type, run_id, data, opts \\ []) do
    Event.new(type, run_id, data, opts)
  end

  # Broadcast Event struct to both run-specific and :all topics
  defp broadcast(%Event{run_id: run_id} = event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(run_id), event)
    Phoenix.PubSub.broadcast(@pubsub, topic(:all), event)
  end

  # Broadcast legacy tuple format
  defp broadcast_legacy(tuple, run_id) do
    Phoenix.PubSub.broadcast(@pubsub, legacy_topic(run_id), tuple)
    Phoenix.PubSub.broadcast(@pubsub, legacy_topic(:all), tuple)
  end

  defp topic(:all), do: "sykli:events:all"
  defp topic(run_id), do: "sykli:events:#{run_id}"

  defp legacy_topic(:all), do: "sykli:events:legacy:all"
  defp legacy_topic(run_id), do: "sykli:events:legacy:#{run_id}"
end
