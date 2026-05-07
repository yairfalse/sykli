defmodule Sykli.Occurrence.PubSub do
  require Logger

  @moduledoc """
  Pub/sub for Occurrence structs.

  Replaces `Sykli.Events`. All messages are `%Sykli.Occurrence{}` structs
  broadcast via Phoenix.PubSub.

  ## Subscribe & Receive

      Sykli.Occurrence.PubSub.subscribe(run_id)

      receive do
        %Sykli.Occurrence{type: "ci.task.completed"} = occ ->
          IO.puts("Task \#{occ.data.task_name} completed!")
      end

  ## Occurrence Types

      "ci.run.started"     — pipeline run begins
      "ci.run.passed"      — all tasks succeeded
      "ci.run.failed"      — one or more tasks failed
      "ci.task.started"    — task begins execution
      "ci.task.completed"  — task finished
      "ci.task.cached"     — task skipped due to cache hit
      "ci.task.skipped"    — task skipped (condition/dependency)
      "ci.task.retrying"   — task failed, retrying
      "ci.task.output"     — task produced output
      "ci.cache.miss"      — cache miss with reason
      "ci.gate.waiting"    — gate awaiting approval
      "ci.gate.resolved"   — gate approved/denied/timed out
      "ci.github.webhook.received" — GitHub webhook accepted
      "ci.github.check_suite.opened" — GitHub check suite opened
      "ci.github.run.dispatched" — GitHub webhook dispatch started
      "ci.github.run.source_acquired" — GitHub source clone succeeded
      "ci.github.run.source_failed" — GitHub source clone failed
      "ci.github.check_run.created" — GitHub check run created
      "ci.github.check_run.transitioned" — GitHub check run status changed
      "ci.github.check_run.transition_failed" — GitHub check run update failed
      "ci.github.check_suite.concluded" — GitHub check suite reached terminal state
  """

  alias Sykli.Occurrence

  @pubsub Sykli.PubSub

  @doc "Subscribe to occurrences for a specific run or all runs."
  def subscribe(run_id \\ :all) do
    Phoenix.PubSub.subscribe(@pubsub, topic(run_id))
  end

  @doc "Unsubscribe from occurrences."
  def unsubscribe(run_id \\ :all) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(run_id))
  end

  @doc "Broadcast a ci.run.started occurrence. Returns the Occurrence."
  def run_started(run_id, project_path, tasks) do
    occ = Occurrence.run_started(run_id, project_path, tasks)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.task.started occurrence. Returns the Occurrence."
  def task_started(run_id, task_name) do
    occ = Occurrence.task_started(run_id, task_name)
    broadcast(occ)
    occ
  end

  @doc """
  Broadcast a `ci.task.output` occurrence.

  Output broadcasts intentionally carry the raw in-memory stream payload so local
  subscribers can render task logs faithfully. Any consumer that persists,
  exports, or republishes these occurrences must apply the normal occurrence
  enrichment/masking path first.
  """
  def task_output(run_id, task_name, output) do
    occ = Occurrence.task_output(run_id, task_name, output)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.task.completed occurrence. Returns the Occurrence."
  def task_completed(run_id, task_name, result) do
    occ = Occurrence.task_completed(run_id, task_name, result)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.run.passed or ci.run.failed occurrence. Returns the Occurrence."
  def run_completed(run_id, result) do
    occ = Occurrence.run_completed(run_id, result)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.task.cached occurrence. Returns the Occurrence."
  def task_cached(run_id, task_name, cache_key \\ nil) do
    occ = Occurrence.task_cached(run_id, task_name, cache_key)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.task.skipped occurrence. Returns the Occurrence."
  def task_skipped(run_id, task_name, reason) do
    occ = Occurrence.task_skipped(run_id, task_name, reason)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.task.retrying occurrence. Returns the Occurrence."
  def task_retrying(run_id, task_name, attempt, max_attempts, opts \\ []) do
    occ = Occurrence.task_retrying(run_id, task_name, attempt, max_attempts, opts)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.cache.miss occurrence. Returns the Occurrence."
  def cache_miss(run_id, task_name, cache_key, reason) do
    occ = Occurrence.cache_miss(run_id, task_name, cache_key, reason)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.gate.waiting occurrence. Returns the Occurrence."
  def gate_waiting(run_id, gate_name, strategy, message, timeout) do
    occ = Occurrence.gate_waiting(run_id, gate_name, strategy, message, timeout)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.gate.resolved occurrence. Returns the Occurrence."
  def gate_resolved(run_id, gate_name, outcome, approver, duration_ms) do
    occ = Occurrence.gate_resolved(run_id, gate_name, outcome, approver, duration_ms)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.github.webhook.received occurrence. Returns the Occurrence."
  def github_webhook_received(run_id, data) do
    occ = Occurrence.github_webhook_received(run_id, data)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.github.check_suite.opened occurrence. Returns the Occurrence."
  def github_check_suite_opened(run_id, data) do
    occ = Occurrence.github_check_suite_opened(run_id, data)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.github.run.dispatched occurrence. Returns the Occurrence."
  def github_run_dispatched(run_id, data) do
    occ = Occurrence.github_run_dispatched(run_id, data)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.github.run.source_acquired occurrence. Returns the Occurrence."
  def github_run_source_acquired(run_id, data) do
    occ = Occurrence.github_run_source_acquired(run_id, data)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.github.run.source_failed occurrence. Returns the Occurrence."
  def github_run_source_failed(run_id, data) do
    occ = Occurrence.github_run_source_failed(run_id, data)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.github.check_run.created occurrence. Returns the Occurrence."
  def github_check_run_created(run_id, data) do
    occ = Occurrence.github_check_run_created(run_id, data)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.github.check_run.transitioned occurrence. Returns the Occurrence."
  def github_check_run_transitioned(run_id, data) do
    occ = Occurrence.github_check_run_transitioned(run_id, data)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.github.check_run.transition_failed occurrence. Returns the Occurrence."
  def github_check_run_transition_failed(run_id, data) do
    occ = Occurrence.github_check_run_transition_failed(run_id, data)
    broadcast(occ)
    occ
  end

  @doc "Broadcast a ci.github.check_suite.concluded occurrence. Returns the Occurrence."
  def github_check_suite_concluded(run_id, data) do
    occ = Occurrence.github_check_suite_concluded(run_id, data)
    broadcast(occ)
    occ
  end

  # Broadcast to both run-specific and :all topics
  defp broadcast(%Occurrence{run_id: run_id} = occ) do
    case Phoenix.PubSub.broadcast(@pubsub, topic(run_id), occ) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("PubSub broadcast failed: #{inspect(reason)}")
    end

    case Phoenix.PubSub.broadcast(@pubsub, topic(:all), occ) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("PubSub broadcast failed: #{inspect(reason)}")
    end
  end

  defp topic(:all), do: "sykli:occurrences:all"
  defp topic(run_id), do: "sykli:occurrences:#{run_id}"
end
