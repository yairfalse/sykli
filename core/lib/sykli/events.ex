defmodule Sykli.Events do
  @moduledoc """
  Pub/sub event system for sykli execution events.

  Events are broadcast locally and can be subscribed to by any process.
  When nodes are connected, PubSub automatically distributes events
  across the cluster.

  ## Event Types

    * `{:run_started, run_id, project_path, tasks}` - A run has begun
    * `{:task_started, run_id, task_name}` - A task is starting execution
    * `{:task_output, run_id, task_name, output}` - Output from a running task
    * `{:task_completed, run_id, task_name, :ok | {:error, reason}}` - Task finished
    * `{:run_completed, run_id, :ok | {:error, reason}}` - All tasks done

  ## Example

      # Subscribe to all events for a run
      Sykli.Events.subscribe(run_id)

      # Subscribe to all events (useful for coordinator)
      Sykli.Events.subscribe(:all)

      # Receive events in your process
      receive do
        {:task_completed, ^run_id, task_name, :ok} ->
          IO.puts("Task \#{task_name} completed!")
      end
  """

  @pubsub Sykli.PubSub

  @doc """
  Subscribe to events for a specific run or all runs.

  - `subscribe(run_id)` - Events for a specific run
  - `subscribe(:all)` - All events (for coordinator/dashboard)
  """
  def subscribe(run_id \\ :all) do
    Phoenix.PubSub.subscribe(@pubsub, topic(run_id))
  end

  @doc """
  Unsubscribe from events.
  """
  def unsubscribe(run_id \\ :all) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(run_id))
  end

  @doc """
  Broadcast a run_started event.
  """
  def run_started(run_id, project_path, tasks) do
    broadcast({:run_started, run_id, project_path, tasks}, run_id)
  end

  @doc """
  Broadcast a task_started event.
  """
  def task_started(run_id, task_name) do
    broadcast({:task_started, run_id, task_name}, run_id)
  end

  @doc """
  Broadcast task output.
  """
  def task_output(run_id, task_name, output) do
    broadcast({:task_output, run_id, task_name, output}, run_id)
  end

  @doc """
  Broadcast a task_completed event.
  """
  def task_completed(run_id, task_name, result) do
    broadcast({:task_completed, run_id, task_name, result}, run_id)
  end

  @doc """
  Broadcast a run_completed event.
  """
  def run_completed(run_id, result) do
    broadcast({:run_completed, run_id, result}, run_id)
  end

  # Broadcast to both the specific run topic and the :all topic
  defp broadcast(event, run_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(run_id), event)
    Phoenix.PubSub.broadcast(@pubsub, topic(:all), event)
  end

  defp topic(:all), do: "sykli:events:all"
  defp topic(run_id), do: "sykli:events:#{run_id}"
end
