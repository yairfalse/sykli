defmodule Sykli.Gui.Provider.Demo do
  @moduledoc """
  Demo Workbench provider — hardcoded, realistically-shaped state.

  Mirrors the design handoff's demo document (extended with the v5
  actor/mandate/audit fields the engine has since grown) so UI work is
  unblocked before the artifact provider exists. Gate actions mutate an
  Agent-held copy of the gates/activity so approve/reject round-trips
  are demoable.
  """

  @behaviour Sykli.Gui.Provider

  alias Sykli.Gui.State

  alias Sykli.Gui.State.{
    Activity,
    AgentCall,
    Contract,
    Edge,
    Evidence,
    Gate,
    Member,
    Node,
    Repo,
    Run,
    Team,
    WorkItem
  }

  @impl true
  def state(opts) do
    %State{
      repo: %Repo{
        name: "false-systems/sykli",
        path: Keyword.get(opts, :repo_path),
        branch: Keyword.get(opts, :branch, "main"),
        dirty: false
      },
      team: %Team{id: "platform", name: "platform", mode: "local_or_team", online: 3, total: 4},
      contract: %Contract{
        valid: true,
        version: 5,
        task_count: 6,
        gate_count: 1,
        review_node_count: 1
      },
      current_actor: %{
        "type" => "member",
        "id" => "yair",
        "name" => "Yair",
        "ref" => "member:Yair"
      },
      latest_run: %Run{
        id: "run-42",
        status: "failed",
        evidence_status: "complete",
        primary_failure_node_id: "test:unit"
      },
      graph: %{nodes: nodes(), edges: edges()},
      members: members(),
      work_items: work_items(),
      gates: gates(),
      evidence: evidence(),
      activity: activity(),
      agent_calls: agent_calls()
    }
  end

  @impl true
  def run("run-" <> _ = id) do
    {:ok,
     %{
       "id" => id,
       "status" => if(id == "run-40", do: "passed", else: "failed"),
       "contractVersion" => if(id == "run-40", do: 3, else: 5),
       "tasks" => 6
     }}
  end

  def run(_id), do: {:error, :not_found}

  @impl true
  def approve_gate("approve-release", actor) do
    {:ok, %{"id" => "approve-release", "status" => "approved", "decidedBy" => actor}}
  end

  def approve_gate(_id, _actor), do: {:error, :not_found}

  @impl true
  def reject_gate("approve-release", actor, reason) do
    {:ok,
     %{
       "id" => "approve-release",
       "status" => "rejected",
       "decidedBy" => actor,
       "reason" => reason
     }}
  end

  def reject_gate(_id, _actor, _reason), do: {:error, :not_found}

  defp nodes do
    [
      %Node{
        id: "format",
        type: "task",
        status: "passed",
        requester: "CI",
        executor: "yair-mbp",
        duration: "2s",
        evidence: "1"
      },
      %Node{
        id: "test:unit",
        type: "task",
        status: "failed",
        failure_class: "criteria_failure",
        retry_hint: "no",
        requester: "Codex",
        executor: "yair-mbp",
        duration: "14s",
        evidence: "complete",
        work_item_id: "fix-flaky",
        mandate_outcome: "kept"
      },
      %Node{
        id: "build",
        type: "task",
        status: "skipped",
        reason: "dependency_failure",
        blocked_by: "test:unit",
        evidence: "none"
      },
      %Node{
        id: "approve-release",
        type: "gate",
        status: "waiting",
        approvers: ["Dana", "Yair"],
        requester: "Codex",
        run_id: "run-42",
        evidence: "complete"
      }
    ]
  end

  defp edges do
    [
      %Edge{from: "format", to: "test:unit"},
      %Edge{from: "test:unit", to: "build"},
      %Edge{from: "build", to: "approve-release"}
    ]
  end

  defp members do
    [
      %Member{
        id: "yair",
        name: "Yair",
        identity_type: "human",
        role: "approver",
        status: "online",
        responsibility: "2 waiting gates · 1 review node assigned",
        recent: "approved approve-deploy · reviewed api_breakage",
        trust: "team platform · approver"
      },
      %Member{
        id: "codex",
        name: "Codex",
        identity_type: "agent",
        role: "executor",
        status: "active",
        current_work: "fix flaky test",
        allowed: ["suggest_tests", "run_pipeline", "get_failure", "run_fix", "get_history"],
        not_allowed: ["approve_gate", "change_team_policy", "mark_evidence_complete"],
        mandate: %{
          scope: ["core/test/**"],
          budget: %{diff_lines: 200, wall_clock_ms: 900_000},
          network: false
        },
        trust: "team platform · executor"
      },
      %Member{
        id: "yair-mbp",
        name: "yair-mbp",
        identity_type: "daemon",
        role: "executor",
        status: "running",
        current_work: "test:unit",
        machine: "local · darwin/arm64",
        allowed: ["run_task", "report_status", "upload_evidence"],
        not_allowed: ["approve_gate"],
        trust: "host token · local"
      },
      %Member{
        id: "dana",
        name: "Dana",
        identity_type: "human",
        role: "reviewer / approver",
        status: "away",
        responsibility: "1 review pending",
        recent: "reviewed flaky_history",
        trust: "team platform · reviewer"
      }
    ]
  end

  defp work_items do
    [
      %WorkItem{
        id: "fix-flaky",
        title: "fix flaky test",
        intent: "Fix flaky test",
        owner: "Codex",
        reviewer: "Dana",
        runs: 3,
        status: "blocked",
        reason: "criteria_failure",
        evidence: "complete",
        participants: "Codex (owner/agent) · yair-mbp (executor) · Dana (reviewer)",
        run_list: "#41 failed · #42 failed · #43 passed"
      },
      %WorkItem{
        id: "release-071",
        title: "release 0.7.1",
        intent: "Cut release 0.7.1",
        owner: "Yair",
        reviewer: "platform",
        runs: 1,
        status: "waiting_gate",
        reason: "approve-release",
        evidence: "partial"
      }
    ]
  end

  defp gates do
    [
      %Gate{
        id: "approve-release",
        status: "waiting",
        requester: "Codex",
        run_id: "run-42",
        evidence: "complete",
        waiting_for: [
          %{name: "Dana", role: "approver", status: "online"},
          %{name: "Yair", role: "approver", status: "online"},
          %{name: "Ops Team", role: "approver group", status: "—"}
        ]
      }
    ]
  end

  defp evidence do
    [
      %Evidence{
        run_id: "run-42",
        status: "failed",
        contract_version: 5,
        tasks: 6,
        failed: 1,
        skipped: 2,
        complete: true,
        audit_verdict: "pass",
        mandates: "1 kept"
      },
      %Evidence{
        run_id: "run-41",
        status: "failed",
        contract_version: 5,
        tasks: 6,
        failed: 1,
        skipped: 2,
        complete: true,
        audit_verdict: "pass",
        mandates: "1 violated"
      },
      %Evidence{
        run_id: "run-40",
        status: "passed",
        contract_version: 3,
        tasks: 6,
        failed: 0,
        skipped: 0,
        complete: true
      }
    ]
  end

  defp activity do
    [
      %Activity{time: "12:41", text: "Codex created work item “fix flaky test”"},
      %Activity{time: "12:42", text: "yair-mbp joined team platform"},
      %Activity{time: "12:43", text: "format passed", kind: "ok"},
      %Activity{time: "12:43", text: "test:unit failed · criteria_failure", kind: "fail"},
      %Activity{time: "12:43", text: "build skipped · dependency_failure", kind: "skip"},
      %Activity{time: "12:44", text: "approve-release gate waiting for approver", kind: "wait"}
    ]
  end

  defp agent_calls do
    [
      %AgentCall{
        tool: "suggest_tests",
        time: "12:41",
        caller: "Codex",
        result: "ok",
        ref: "fix flaky test",
        changed_state: true
      },
      %AgentCall{
        tool: "run_pipeline",
        time: "12:42",
        caller: "Codex",
        result: "ok",
        ref: "run #42",
        changed_state: true
      },
      %AgentCall{
        tool: "get_failure",
        time: "12:43",
        caller: "Codex",
        result: "ok",
        ref: "test:unit",
        changed_state: false
      },
      %AgentCall{
        tool: "run_fix",
        time: "—",
        caller: "Codex",
        result: "pending",
        ref: "fix flaky test"
      },
      %AgentCall{
        tool: "get_history",
        time: "—",
        caller: "Codex",
        result: "pending",
        ref: "test:unit"
      }
    ]
  end
end
