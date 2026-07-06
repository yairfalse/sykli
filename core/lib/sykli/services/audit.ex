defmodule Sykli.Services.Audit do
  @moduledoc """
  Read-time contract audit over recorded run manifests.

  The audit is a judgment over evidence — a pure function of the run
  manifest and the current `sykli.lock` — computed at read time, never
  persisted. That is deliberate: the lock comparison is inherently a
  read-time question (re-locking after a run *should* flip that run's
  verdict to fail), and `.sykli/` stores evidence, not judgments.
  Persisting verdicts would freeze the weaker claim "matched the lock at
  the time" and invite dual-write drift.

  Shared by every audit surface — CLI (`sykli audit`), MCP, and the
  Workbench — so verdict semantics exist in exactly one place.
  """

  alias Sykli.RunHistory

  @type result :: %{run_id: String.t(), verdict: String.t(), findings: [map()]}

  @doc """
  Audits a recorded run by id.

  Loads the manifest through `RunHistory.get/2` and returns
  `{:error, :not_found | :corrupt}` on load failure.
  """
  @spec audit(String.t(), String.t()) :: {:ok, result()} | {:error, :not_found | :corrupt}
  def audit(path, run_id) do
    with {:ok, run} <- RunHistory.get(run_id, path: path) do
      {:ok, audit_run(path, run)}
    end
  end

  @doc """
  Audits an already-loaded run manifest against the project at `path`.

  Verdict is `"fail"` when any finding fails, `"pass"` otherwise.
  Findings are `%{"check", "status", "message"}` maps with optional
  `"task"` and `"details"`.
  """
  @spec audit_run(String.t(), RunHistory.Run.t()) :: result()
  def audit_run(path, %RunHistory.Run{} = run) do
    findings =
      []
      |> maybe_lock_finding(path, run)
      |> success_criteria_findings(run)
      |> evidence_findings(run)
      |> mandate_findings(run)
      |> Enum.reverse()

    verdict = if Enum.any?(findings, &(&1["status"] == "fail")), do: "fail", else: "pass"

    %{
      run_id: run.id,
      verdict: verdict,
      findings: findings
    }
  end

  defp maybe_lock_finding(findings, path, run) do
    lock_path = Path.join(path, "sykli.lock")

    if File.exists?(lock_path) do
      case Sykli.ContractLock.read(lock_path) do
        {:ok, %{"contract_hash" => hash}} ->
          [lock_hash_finding(hash, run.contract_hash) | findings]

        {:error, error} ->
          [finding("lock_contract_hash", "fail", Exception.message(error)) | findings]
      end
    else
      findings
    end
  end

  # Runs not started via `sykli run --work <id>` never record a contract
  # hash, so there is nothing to compare against the lock — that is not a
  # mismatch, and must not fail the audit.
  defp lock_hash_finding(_lock_hash, nil) do
    finding(
      "lock_contract_hash",
      "skip",
      "run has no recorded contract hash; lock comparison skipped"
    )
  end

  defp lock_hash_finding(lock_hash, run_hash) when lock_hash == run_hash do
    finding("lock_contract_hash", "pass", "lock hash matches run")
  end

  defp lock_hash_finding(lock_hash, run_hash) do
    finding("lock_contract_hash", "fail", "lock hash does not match run", nil,
      expected: lock_hash,
      observed: run_hash
    )
  end

  defp success_criteria_findings(findings, run) do
    Enum.reduce(run.tasks, findings, fn task, acc ->
      declared = get_in(task.contract_slice || %{}, ["success_criteria"]) || []

      if declared != [] and task.success_criteria_results == [] do
        [
          finding("success_criteria_recorded", "fail", "success criteria result missing", task)
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp evidence_findings(findings, run) do
    Enum.reduce(run.tasks, findings, fn task, acc ->
      declared = get_in(task.contract_slice || %{}, ["evidence_required"]) || []

      if declared != [] and task.evidence_results == [] do
        [finding("evidence_recorded", "fail", "evidence result missing", task) | acc]
      else
        acc
      end
    end)
  end

  defp mandate_findings(findings, run) do
    Enum.reduce(run.tasks, findings, fn task, acc ->
      actor = get_in(task.contract_slice || %{}, ["actor"]) || %{}
      mandate = get_in(task.contract_slice || %{}, ["mandate"])

      if actor["kind"] == "agent" and mandate != nil and task.mandate_outcome == nil do
        [finding("mandate_outcome_recorded", "fail", "mandate outcome missing", task) | acc]
      else
        acc
      end
    end)
  end

  defp finding(check, status, message, task \\ nil, details \\ []) do
    %{
      "check" => check,
      "status" => status,
      "message" => message
    }
    |> maybe_put("task", task_name(task))
    |> maybe_put("details", if(details == [], do: nil, else: Map.new(details)))
  end

  defp task_name(%RunHistory.TaskResult{name: name}), do: name
  defp task_name(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
