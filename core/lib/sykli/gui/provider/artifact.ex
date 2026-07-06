defmodule Sykli.Gui.Provider.Artifact do
  @moduledoc """
  Artifact-backed Workbench provider — real local data, zero execution.

  Builds the same `%Sykli.Gui.State{}` the demo provider returns, but from
  the repo's actual local sources:

    * repo identity — git (origin remote, branch, dirty flag)
    * contract — `sykli.lock` first, `.sykli/context.json` second; this
      provider never runs the SDK file. `GET /api/state` must not execute
      repo code, so a repo that has never been locked or `sykli context`-ed
      simply shows no contract until one of those runs.
    * runs + evidence — `.sykli/runs/` manifests via `Sykli.RunHistory`
    * work items — `Sykli.Work.Store`
    * gates — `Sykli.Gate.Store`; approve/reject write through it, so a
      decision made in the Workbench is the same artifact `sykli gate`
      produces
    * activity — derived from the artifacts above

  Local-only for now: the member list is the local git identity plus any
  v5 agent/service actors declared in the contract (with their mandates),
  `team` is the local pseudo-team, and `agent_calls` is empty (no local
  artifact records MCP tool calls yet). Coordinator-backed team state is a
  later Team Mode phase.

  v5 result fields: task `mandate_outcome` and per-run mandate summaries
  are read shape-tolerantly from run manifests — they populate once
  mandate enforcement (PR #276) starts persisting them; `audit_verdict`
  stays nil until the audit core is a shared service the GUI can call.
  """

  @behaviour Sykli.Gui.Provider

  alias Sykli.{ContractLock, GateDecision, RunHistory}
  alias Sykli.Gui.State
  alias Sykli.Gui.State.{Activity, Contract, Edge, Evidence, Member, Node, Repo, Run, Team}

  @recent_runs 5
  @scan_runs 20
  @default_decision_reason "decided via workbench"

  # ----- Provider callbacks -----

  @impl true
  def state(opts) do
    path = Keyword.get(opts, :repo_path) || File.cwd!()
    contract = load_contract(path)
    runs = list_runs(path, @scan_runs)
    latest = List.first(runs)
    items = list_work_items(path)
    gates = list_gates(path)

    %State{
      repo: repo(path),
      team: %Team{id: "local", name: "local", mode: "local", online: 1, total: 1},
      contract: contract_summary(contract),
      current_actor: local_actor(path),
      latest_run: latest && run_row(latest),
      graph: graph(contract, latest),
      members: members(path) ++ actor_members(contract),
      work_items: Enum.map(items, &work_item_row(&1, runs)),
      gates: Enum.map(gates, &gate_row/1),
      evidence: runs |> Enum.take(@recent_runs) |> Enum.map(&evidence_row/1),
      activity: derive_activity(runs, gates, items),
      agent_calls: []
    }
  end

  @impl true
  def run(id), do: run(id, [])

  def run(id, opts) do
    path = Keyword.get(opts, :repo_path) || File.cwd!()

    case Enum.find(list_runs(path, :all), &(&1.id == id)) do
      nil -> {:error, :not_found}
      run -> {:ok, run_detail(run)}
    end
  end

  @impl true
  def approve_gate(id, actor), do: approve_gate(id, actor, [])

  def approve_gate(id, actor, opts), do: decide_gate(:approve, id, actor, "", opts)

  @impl true
  def reject_gate(id, actor, reason), do: reject_gate(id, actor, reason, [])

  def reject_gate(id, actor, reason, opts), do: decide_gate(:reject, id, actor, reason, opts)

  # ----- Gates -----

  defp decide_gate(action, id, actor, reason, opts) do
    path = Keyword.get(opts, :repo_path) || File.cwd!()
    reason = if String.trim(reason) == "", do: @default_decision_reason, else: reason
    store_opts = [path: path, decided_by: qualify_actor(actor)]

    result =
      case action do
        :approve -> Sykli.Gate.Store.approve(id, reason, store_opts)
        :reject -> Sykli.Gate.Store.reject(id, reason, store_opts)
      end

    case result do
      {:ok, gate} -> {:ok, State.JSON.encode(GateDecision.to_map(gate))}
      {:error, {:gate_not_found, _id}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # `decided_by` is a compact actor ref ("member:yair"); qualify bare names
  # from the UI so Workbench decisions match the CLI's attribution format.
  defp qualify_actor(actor) do
    if String.contains?(actor, ":"), do: actor, else: "member:" <> actor
  end

  defp gate_row(%GateDecision{} = gate) do
    %State.Gate{
      id: gate.id,
      status: gate.status,
      requester: gate.requested_by_id,
      run_id: gate.run_id,
      evidence: evidence_refs_label(gate.evidence_refs),
      waiting_for: []
    }
  end

  defp evidence_refs_label([]), do: nil
  defp evidence_refs_label(refs) when is_list(refs), do: "#{length(refs)} refs"
  defp evidence_refs_label(_), do: nil

  # ----- Repo / members -----

  defp repo(path) do
    %Repo{
      name: repo_name(path),
      path: path,
      branch: git(path, ["rev-parse", "--abbrev-ref", "HEAD"]) || "unknown",
      dirty: git(path, ["status", "--porcelain"]) not in [nil, ""]
    }
  end

  defp repo_name(path) do
    case git(path, ["remote", "get-url", "origin"]) do
      nil ->
        Path.basename(Path.expand(path))

      url ->
        url
        |> String.trim_trailing(".git")
        |> String.split(~r{[:/]})
        |> Enum.take(-2)
        |> Enum.join("/")
    end
  end

  defp members(path) do
    actor = local_actor(path)
    name = actor["name"]

    [
      %Member{
        id: actor["id"],
        name: name,
        identity_type: "human",
        role: "approver",
        status: "online",
        trust: "local repo owner"
      }
    ]
  end

  defp local_actor(path) do
    name = git(path, ["config", "user.name"]) || "local"

    %{
      "type" => "member",
      "id" => name |> String.downcase() |> String.replace(~r/\s+/, "-"),
      "name" => name,
      "ref" => "member:" <> name
    }
  end

  # v5 actors declared in the contract are execution participants the
  # Workbench must show — with their mandate — even before any run. They
  # are declarations, not live presence, so status is "declared".
  defp actor_members({:ok, %{"tasks" => tasks}, _version}) do
    tasks
    |> Enum.filter(&(get_in(&1, ["actor", "kind"]) in ["agent", "service"]))
    |> Enum.group_by(&get_in(&1, ["actor", "id"]))
    |> Enum.sort()
    |> Enum.map(fn {actor_id, actor_tasks} ->
      first = List.first(actor_tasks)
      kind = get_in(first, ["actor", "kind"])

      %Member{
        id: actor_id || kind,
        name: actor_id || kind,
        identity_type: kind,
        role: "executor",
        status: "declared",
        current_work: Enum.map_join(actor_tasks, " · ", & &1["name"]),
        mandate: first["mandate"],
        trust: "declared in contract"
      }
    end)
  end

  defp actor_members(_contract), do: []

  defp git(path, args) do
    case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ----- Contract -----

  defp load_contract(path) do
    lock_path = Path.join(path, ContractLock.filename())

    with true <- File.exists?(lock_path),
         {:ok, lock} <- ContractLock.read(lock_path),
         %{"tasks" => tasks} when is_list(tasks) <- lock["contract"] do
      {:ok, lock["contract"], parse_version(lock["schema_version"])}
    else
      _ -> load_context_contract(path)
    end
  end

  defp load_context_contract(path) do
    with {:ok, bytes} <- File.read(Path.join(path, ".sykli/context.json")),
         {:ok, %{"pipeline" => %{"tasks" => tasks}}} when is_list(tasks) <- Jason.decode(bytes) do
      {:ok, %{"tasks" => tasks}, nil}
    else
      _ -> :none
    end
  end

  defp contract_summary(:none), do: %Contract{valid: false}

  defp contract_summary({:ok, contract, version}) do
    tasks = contract["tasks"] || []

    %Contract{
      valid: true,
      version: version,
      task_count: length(tasks),
      gate_count: Enum.count(tasks, &gate_task?/1),
      review_node_count: Enum.count(tasks, &(&1["kind"] == "review"))
    }
  end

  defp gate_task?(task), do: task["gate"] not in [nil, false]

  defp parse_version(value) when is_binary(value) do
    case Integer.parse(value) do
      {version, ""} -> version
      _ -> nil
    end
  end

  defp parse_version(_), do: nil

  # ----- Graph -----

  defp graph({:ok, %{"tasks" => tasks}, _version}, latest) when tasks != [] do
    results = task_results(latest)

    %{
      nodes: Enum.map(tasks, &contract_node(&1, results)),
      edges: contract_edges(tasks)
    }
  end

  defp graph(_contract, nil), do: %{nodes: [], edges: []}

  defp graph(_contract, latest) do
    %{nodes: Enum.map(latest.tasks, &result_node/1), edges: []}
  end

  defp task_results(nil), do: %{}
  defp task_results(run), do: Map.new(run.tasks, &{&1.name, &1})

  defp contract_node(task, results) do
    name = task["name"]

    case results[name] do
      # Matrix expansion renames tasks, and a fresh contract may not have
      # run yet — a contract node without a result is simply pending.
      nil -> %Node{id: name, type: node_type(task), status: "pending"}
      result -> %{result_node(result) | type: node_type(task)}
    end
  end

  defp node_type(task) do
    cond do
      gate_task?(task) -> "gate"
      task["kind"] == "review" -> "review"
      true -> "task"
    end
  end

  defp result_node(result) do
    semantics = result.failure_semantics

    %Node{
      id: result.name,
      type: if(result.kind == "review", do: "review", else: "task"),
      status: result_status(result),
      failure_class: semantics && to_string(semantics.class),
      retry_hint: semantics && if(semantics.retryable, do: "yes", else: "no"),
      reason: result_reason(result),
      duration: format_duration(result),
      evidence: task_evidence_label(result),
      mandate_outcome: mandate_outcome_label(result)
    }
  end

  # `mandate_outcome` is persisted by mandate enforcement (PR #276) as
  # %{"status" => "kept" | "violated" | "unverified" | "unsupported", ...}.
  # Read it shape-tolerantly: manifests written before enforcement (or by
  # engines without it) simply have no outcome. Exposed for tests until
  # the TaskResult struct carries the field on main.
  @doc false
  def mandate_outcome_label(result) do
    case Map.get(result, :mandate_outcome) do
      %{"status" => status} when is_binary(status) -> status
      _ -> nil
    end
  end

  @doc false
  def mandate_summary(tasks) do
    counts =
      tasks
      |> Enum.map(&mandate_outcome_label/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    if counts == %{} do
      nil
    else
      counts
      |> Enum.sort()
      |> Enum.map_join(" · ", fn {status, n} -> "#{n} #{status}" end)
    end
  end

  defp result_status(%{cached: true}), do: "cached"
  defp result_status(result), do: to_string(result.status)

  defp result_reason(%{status: :failed} = result) do
    case result.failure_semantics do
      %{reason: reason} when not is_nil(reason) -> to_string(reason)
      _ -> result.error
    end
  end

  defp result_reason(%{status: :skipped} = result), do: result.error
  defp result_reason(_result), do: nil

  defp format_duration(%{status: :skipped}), do: nil
  defp format_duration(%{cached: true}), do: nil

  defp format_duration(%{duration_ms: ms}) when is_integer(ms) do
    if ms < 1000, do: "#{ms}ms", else: "#{Float.round(ms / 1000, 1)}s"
  end

  defp format_duration(_result), do: nil

  defp task_evidence_label(result) do
    case result.evidence_results do
      results when is_list(results) and results != [] ->
        if Enum.all?(results, &evidence_satisfied?/1), do: "complete", else: "partial"

      _ ->
        nil
    end
  end

  defp contract_edges(tasks) do
    names = MapSet.new(tasks, & &1["name"])

    tasks
    |> Enum.flat_map(fn task ->
      deps = List.wrap(task["needs"]) ++ List.wrap(task["depends_on"])
      for dep <- deps, MapSet.member?(names, dep), do: %Edge{from: dep, to: task["name"]}
    end)
    |> Enum.uniq()
  end

  # ----- Runs / evidence -----

  defp list_runs(path, limit) do
    case RunHistory.list(path: path, limit: limit) do
      {:ok, runs} -> runs
      _ -> []
    end
  end

  defp run_row(run) do
    failed = Enum.find(run.tasks, &(&1.status == :failed))

    %Run{
      id: run.id,
      status: to_string(run.overall),
      evidence_status: run_evidence_status(run),
      primary_failure_node_id: failed && failed.name,
      started_at: DateTime.to_iso8601(run.timestamp)
    }
  end

  defp evidence_row(run) do
    %Evidence{
      run_id: run.id,
      status: to_string(run.overall),
      tasks: length(run.tasks),
      failed: Enum.count(run.tasks, &(&1.status == :failed)),
      skipped: Enum.count(run.tasks, &(&1.status == :skipped)),
      complete: run_evidence_status(run) == "complete",
      # audit_verdict stays nil until the audit core (`sykli audit`,
      # PR #276) is extractable as a shared service — the GUI must not
      # re-derive verdict logic.
      mandates: mandate_summary(run.tasks)
    }
  end

  defp run_evidence_status(run) do
    results = Enum.flat_map(run.tasks, &(&1.evidence_results || []))

    cond do
      results == [] -> nil
      Enum.all?(results, &evidence_satisfied?/1) -> "complete"
      true -> "partial"
    end
  end

  defp evidence_satisfied?(%{status: status}), do: status in [:satisfied, "satisfied"]
  defp evidence_satisfied?(_), do: false

  defp run_detail(run) do
    %{
      "id" => run.id,
      "status" => to_string(run.overall),
      "timestamp" => DateTime.to_iso8601(run.timestamp),
      "branch" => run.git_branch,
      "workItemId" => run.work_item_id,
      "tasks" => length(run.tasks),
      "failed" => Enum.count(run.tasks, &(&1.status == :failed)),
      "skipped" => Enum.count(run.tasks, &(&1.status == :skipped)),
      "taskResults" =>
        Enum.map(run.tasks, fn task ->
          %{
            "name" => task.name,
            "status" => result_status(task),
            "durationMs" => task.duration_ms,
            "cached" => task.cached
          }
        end)
    }
  end

  # ----- Work items -----

  defp list_work_items(path) do
    case Sykli.Work.Store.list(path: path) do
      {:ok, items} -> items
      _ -> []
    end
  end

  defp work_item_row(item, runs) do
    item_runs = Enum.filter(runs, &(&1.work_item_id == item.id))

    %State.WorkItem{
      id: item.id,
      title: item.title,
      intent: item.intent,
      owner: item.assigned_to_id || item.created_by_id,
      status: item.status,
      runs: length(item_runs),
      run_list: run_list_label(item_runs)
    }
  end

  defp run_list_label([]), do: nil

  defp run_list_label(runs) do
    Enum.map_join(runs, " · ", &"#{short_id(&1.id)} #{&1.overall}")
  end

  defp short_id(id) when is_binary(id) and byte_size(id) > 6, do: String.slice(id, -6..-1)
  defp short_id(id), do: id

  defp list_gates(path) do
    case Sykli.Gate.Store.list(path: path) do
      {:ok, gates} -> gates
      _ -> []
    end
  end

  # ----- Activity -----

  # The feed today: latest-run task outcomes plus waiting gates, newest
  # first. What else belongs here (gate decisions, work-item notes, run
  # verification) is a product call — extend the event list below.
  defp derive_activity(runs, gates, _items) do
    run_events =
      case runs do
        [latest | _] ->
          time = fmt_time(latest.timestamp)
          Enum.map(latest.tasks, &%Activity{time: time, text: task_text(&1), kind: task_kind(&1)})

        [] ->
          []
      end

    gate_events =
      for gate <- gates, gate.status == "waiting" do
        %Activity{
          time: fmt_time(gate.updated_at),
          text: "#{gate.id} gate waiting for approver",
          kind: "wait"
        }
      end

    gate_events ++ run_events
  end

  defp task_text(task) do
    base = "#{task.name} #{result_status(task)}"

    case result_reason(task) do
      nil -> base
      reason -> "#{base} · #{reason}"
    end
  end

  defp task_kind(%{cached: true}), do: "ok"
  defp task_kind(%{status: :passed}), do: "ok"
  defp task_kind(%{status: :failed}), do: "fail"
  defp task_kind(%{status: :skipped}), do: "skip"
  defp task_kind(_task), do: nil

  defp fmt_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")

  defp fmt_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> fmt_time(dt)
      _ -> "—"
    end
  end

  defp fmt_time(_), do: "—"
end
