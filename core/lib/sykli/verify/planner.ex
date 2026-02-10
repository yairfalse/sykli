defmodule Sykli.Verify.Planner do
  @moduledoc """
  Pure planning logic for cross-platform verification.

  Takes a run manifest, task graph, local labels, and remote node capabilities.
  Returns a `%Verify.Plan{}` describing which tasks to re-run where.

  ## Decision Logic (per task)

  1. Skip if status was :cached or :skipped in the run
  2. Skip if task has `verify: "never"`
  3. Skip if no remote nodes available
  4. Verify if `verify: "always"` — find any remote node
  5. Verify if `verify: "cross_platform"` — find node with different OS/arch
  6. Verify if task failed locally — retry on different platform
  7. Default: verify if a node with different platform labels exists

  This module has no side effects — it's pure data transformation.
  """

  alias Sykli.Verify.Plan
  alias Sykli.Verify.Plan.Entry

  @doc """
  Generate a verification plan.

  ## Parameters

    - `run` - `%RunHistory.Run{}` from the latest (or specified) run
    - `tasks` - map of task name => `%Graph.Task{}` (the full task graph)
    - `local_labels` - list of labels for the local node (e.g., ["darwin", "arm64"])
    - `remote_nodes` - list of `%{node: atom, labels: [String.t()]}` for each remote node

  ## Returns

    `%Plan{}` with entries (tasks to verify) and skipped (tasks to skip with reasons)
  """
  @spec plan(map(), map(), [String.t()], [map()]) :: Plan.t()
  def plan(run, tasks, local_labels, remote_nodes) do
    {entries, skipped} =
      run.tasks
      |> Enum.reduce({[], []}, fn task_result, {entries_acc, skipped_acc} ->
        task = Map.get(tasks, task_result.name)
        decide(task_result, task, local_labels, remote_nodes, entries_acc, skipped_acc)
      end)

    %Plan{
      entries: Enum.reverse(entries),
      skipped: Enum.reverse(skipped),
      local_labels: local_labels,
      remote_nodes: remote_nodes
    }
  end

  # ── Decision logic per task ──────────────────────────────────────────────────

  defp decide(task_result, nil, _local_labels, _remote_nodes, entries, skipped) do
    # Task no longer exists in graph — skip
    {entries, [{task_result.name, :task_not_found} | skipped]}
  end

  defp decide(task_result, _task, _local_labels, _remote_nodes, entries, skipped)
       when task_result.status == :skipped do
    {entries, [{task_result.name, :skipped} | skipped]}
  end

  defp decide(task_result, _task, _local_labels, _remote_nodes, entries, skipped)
       when task_result.cached == true do
    {entries, [{task_result.name, :cached} | skipped]}
  end

  defp decide(task_result, task, local_labels, remote_nodes, entries, skipped) do
    verify_mode = get_verify_mode(task)

    case verify_mode do
      "never" ->
        {entries, [{task_result.name, :verify_never} | skipped]}

      _ ->
        decide_with_mode(task_result, task, verify_mode, local_labels, remote_nodes, entries, skipped)
    end
  end

  defp decide_with_mode(task_result, _task, _mode, _local_labels, [], entries, skipped) do
    # No remote nodes available
    {entries, [{task_result.name, :no_remote_nodes} | skipped]}
  end

  defp decide_with_mode(task_result, _task, "always", _local_labels, remote_nodes, entries, skipped) do
    # Verify on any remote node
    node = List.first(remote_nodes)

    entry = %Entry{
      task_name: task_result.name,
      target_node: node.node,
      target_labels: node.labels,
      reason: :explicit_verify
    }

    {[entry | entries], skipped}
  end

  defp decide_with_mode(task_result, _task, "cross_platform", local_labels, remote_nodes, entries, skipped) do
    case find_different_platform_node(local_labels, remote_nodes) do
      nil ->
        {entries, [{task_result.name, :same_platform} | skipped]}

      node ->
        entry = %Entry{
          task_name: task_result.name,
          target_node: node.node,
          target_labels: node.labels,
          reason: :cross_platform
        }

        {[entry | entries], skipped}
    end
  end

  defp decide_with_mode(task_result, _task, _mode, local_labels, remote_nodes, entries, skipped)
       when task_result.status == :failed do
    # Failed locally — retry on a different platform if available
    case find_different_platform_node(local_labels, remote_nodes) do
      nil ->
        # Try any remote node
        node = List.first(remote_nodes)

        entry = %Entry{
          task_name: task_result.name,
          target_node: node.node,
          target_labels: node.labels,
          reason: :retry_on_different_platform
        }

        {[entry | entries], skipped}

      node ->
        entry = %Entry{
          task_name: task_result.name,
          target_node: node.node,
          target_labels: node.labels,
          reason: :retry_on_different_platform
        }

        {[entry | entries], skipped}
    end
  end

  defp decide_with_mode(task_result, _task, _mode, local_labels, remote_nodes, entries, skipped) do
    # Default: verify if a node with different platform exists
    case find_different_platform_node(local_labels, remote_nodes) do
      nil ->
        {entries, [{task_result.name, :same_platform} | skipped]}

      node ->
        entry = %Entry{
          task_name: task_result.name,
          target_node: node.node,
          target_labels: node.labels,
          reason: :cross_platform
        }

        {[entry | entries], skipped}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @platform_labels ~w(darwin linux unix windows arm64 amd64)

  defp get_verify_mode(%{verify: mode}) when is_binary(mode), do: mode
  defp get_verify_mode(_), do: nil

  @doc false
  def find_different_platform_node(local_labels, remote_nodes) do
    local_platform = platform_labels(local_labels)

    Enum.find(remote_nodes, fn node ->
      remote_platform = platform_labels(node.labels)
      remote_platform != local_platform
    end)
  end

  defp platform_labels(labels) do
    labels
    |> Enum.filter(&(&1 in @platform_labels))
    |> Enum.sort()
  end
end
