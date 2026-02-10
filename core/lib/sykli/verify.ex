defmodule Sykli.Verify do
  @moduledoc """
  Cross-platform verification orchestrator.

  Takes a local run manifest, discovers mesh nodes, computes which tasks
  need cross-platform verification, dispatches them to remote BEAM nodes,
  and merges results back into an enriched manifest.

  ## Workflow

      sykli verify               → loads manifest, discovers mesh nodes
                                 → computes which tasks need cross-platform verification
                                 → dispatches ONLY those tasks to remote nodes
                                 → merges results back into enriched manifest

  ## Public Functions

    - `verify/2` — full verification (load → plan → dispatch → merge → save)
    - `plan/2` — dry-run (load → plan → return plan)
  """

  alias Sykli.{RunHistory, Mesh, NodeProfile, Verify.Planner, Verify.Plan}

  @doc """
  Run full cross-platform verification.

  Loads the run manifest, generates a verification plan, dispatches tasks
  to remote nodes, and saves the enriched manifest.

  ## Options

    - `:from` - `"latest"` (default) or a run ID
    - `:path` - base path (default: `"."`)
    - `:json` - if true, return structured data instead of printing
    - `:discover_fn` - `(-> [node_map])` override for node discovery
    - `:labels_fn` - `(-> [String.t()])` override for local labels
    - `:dispatch_fn` - `(task, node, opts -> :ok | {:error, term()})` override for dispatch

  ## Returns

    - `{:ok, %Plan{}}` on success (with results merged into the run manifest)
    - `{:error, reason}` on failure
  """
  @spec verify(keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def verify(opts \\ []) do
    path = Keyword.get(opts, :path, ".")
    dispatch_fn = Keyword.get(opts, :dispatch_fn, &Mesh.dispatch_task/3)

    with {:ok, run} <- load_run(opts),
         {:ok, tasks} <- load_task_graph(path),
         {:ok, plan} <- do_plan(run, tasks, opts) do
      # Dispatch tasks to remote nodes
      results = dispatch_entries(plan, tasks, path, dispatch_fn)

      # Merge results back into the run manifest
      enriched_run = merge_results(run, plan, results)

      # Save enriched manifest
      RunHistory.save(enriched_run, path: path)

      {:ok, plan}
    end
  end

  @doc """
  Generate a verification plan without executing (dry-run).

  ## Options

    - `:from` - `"latest"` (default) or a run ID
    - `:path` - base path (default: `"."`)

  ## Returns

    - `{:ok, %Plan{}}` with entries and skipped tasks
    - `{:error, reason}` on failure
  """
  @spec plan(keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(opts \\ []) do
    path = Keyword.get(opts, :path, ".")

    with {:ok, run} <- load_run(opts),
         {:ok, tasks} <- load_task_graph(path) do
      do_plan(run, tasks, opts)
    end
  end

  # ── Internal ────────────────────────────────────────────────────────────────

  defp load_run(opts) do
    path = Keyword.get(opts, :path, ".")
    from = Keyword.get(opts, :from, "latest")

    case from do
      "latest" ->
        RunHistory.load_latest(path: path)

      run_id ->
        load_run_by_id(run_id, path)
    end
  end

  defp load_run_by_id(run_id, path) do
    case RunHistory.list(path: path, limit: 100) do
      {:ok, runs} ->
        case Enum.find(runs, fn run -> run.id == run_id end) do
          nil -> {:error, {:run_not_found, run_id}}
          run -> {:ok, run}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_task_graph(path) do
    with {:ok, sdk_file} <- Sykli.Detector.find(path),
         {:ok, json} <- Sykli.Detector.emit(sdk_file),
         {:ok, graph} <- Sykli.Graph.parse(json) do
      {:ok, Sykli.Graph.expand_matrix(graph)}
    end
  end

  defp do_plan(run, tasks, opts) do
    labels_fn = Keyword.get(opts, :labels_fn, &NodeProfile.labels/0)
    discover_fn = Keyword.get(opts, :discover_fn, &discover_remote_nodes/0)

    local_labels = labels_fn.()
    remote_nodes = discover_fn.()

    plan = Planner.plan(run, tasks, local_labels, remote_nodes)
    {:ok, plan}
  end

  defp discover_remote_nodes do
    if Node.alive?() do
      Node.list()
      |> Enum.flat_map(fn node ->
        case :rpc.call(node, Sykli.NodeProfile, :capabilities, [], 5000) do
          {:badrpc, _} ->
            []

          caps ->
            [%{node: node, labels: caps[:labels] || []}]
        end
      end)
    else
      []
    end
  end

  defp dispatch_entries(plan, tasks, path, dispatch_fn) do
    plan.entries
    |> Enum.map(fn entry ->
      task = Map.get(tasks, entry.task_name)

      {entry.task_name,
       Task.async(fn ->
         dispatch_fn.(task, entry.target_node, workdir: path)
       end)}
    end)
    |> Enum.map(fn {name, async_task} ->
      result =
        case Task.yield(async_task, 300_000) || Task.shutdown(async_task, :brutal_kill) do
          {:ok, res} -> res
          nil -> {:error, :timeout}
          {:exit, reason} -> {:error, reason}
        end

      {name, result}
    end)
    |> Map.new()
  end

  @doc false
  def merge_results(run, plan, results) do
    enriched_tasks =
      Enum.map(run.tasks, fn task_result ->
        case Map.get(results, task_result.name) do
          nil ->
            task_result

          :ok ->
            entry = Enum.find(plan.entries, fn e -> e.task_name == task_result.name end)
            node_name = if entry, do: to_string(entry.target_node), else: nil
            %{task_result | verified_on: node_name}

          {:error, _reason} ->
            entry = Enum.find(plan.entries, fn e -> e.task_name == task_result.name end)
            node_name = if entry, do: to_string(entry.target_node), else: nil
            %{task_result | verified_on: node_name}
        end
      end)

    verification = %{
      "entries" => length(plan.entries),
      "skipped" => length(plan.skipped),
      "passed" => Enum.count(results, fn {_k, v} -> v == :ok end),
      "failed" => Enum.count(results, fn {_k, v} -> v != :ok end)
    }

    %{run | tasks: enriched_tasks, verified: true, verification: verification}
  end
end
