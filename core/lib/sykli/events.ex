defmodule Sykli.Events do
  @moduledoc """
  Deprecated — use `Sykli.Occurrence.PubSub` instead.

  This module is kept as a thin redirect during migration.
  All functions delegate to `Sykli.Occurrence.PubSub`.
  """

  alias Sykli.Occurrence.PubSub, as: OccPubSub

  defdelegate subscribe(run_id \\ :all), to: OccPubSub
  defdelegate unsubscribe(run_id \\ :all), to: OccPubSub
  defdelegate run_started(run_id, project_path, tasks), to: OccPubSub
  defdelegate task_started(run_id, task_name), to: OccPubSub
  defdelegate task_output(run_id, task_name, output), to: OccPubSub
  defdelegate task_completed(run_id, task_name, result), to: OccPubSub
  defdelegate run_completed(run_id, result), to: OccPubSub
  defdelegate gate_waiting(run_id, gate_name, strategy, message, timeout), to: OccPubSub
  defdelegate gate_resolved(run_id, gate_name, outcome, approver, duration_ms), to: OccPubSub
end
