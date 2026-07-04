defmodule Sykli.CLI.Audit do
  @moduledoc false

  alias Sykli.CLI.JsonResponse
  alias Sykli.RunHistory

  def run(args, opts \\ []) do
    {json?, rest} = parse_args(args)
    path = Keyword.get(opts, :path, ".")

    case rest do
      [run_id] ->
        run_audit(path, run_id, json?)

      [] ->
        emit_error(json?, audit_error("audit.run_not_found", "run id is required"))
        1

      _ ->
        emit_error(json?, audit_error("audit.invalid_args", "usage: sykli audit <run-id>"))
        1
    end
  end

  defp parse_args(args) do
    json? = Enum.member?(args, "--json")
    rest = Enum.reject(args, &(&1 == "--json"))
    {json?, rest}
  end

  defp run_audit(path, run_id, json?) do
    case load_run(path, run_id) do
      {:ok, run} ->
        result = audit_run(path, run)
        emit_result(json?, result)
        if result.verdict == "pass", do: 0, else: 1

      {:error, :not_found} ->
        emit_error(json?, audit_error("audit.run_not_found", "run not found: #{run_id}"))
        1
    end
  end

  defp load_run(path, run_id) do
    with {:ok, runs} <- RunHistory.list(path: path, limit: :all),
         %RunHistory.Run{} = run <- Enum.find(runs, &(&1.id == run_id)) do
      {:ok, run}
    else
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp audit_run(path, %RunHistory.Run{} = run) do
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
        {:ok, %{"contract_hash" => hash}} when hash == run.contract_hash ->
          [finding("lock_contract_hash", "pass", "lock hash matches run") | findings]

        {:ok, %{"contract_hash" => hash}} ->
          [
            finding("lock_contract_hash", "fail", "lock hash does not match run",
              expected: hash,
              observed: run.contract_hash
            )
            | findings
          ]

        {:error, error} ->
          [finding("lock_contract_hash", "fail", Exception.message(error)) | findings]
      end
    else
      findings
    end
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

  defp emit_result(true, result), do: IO.puts(JsonResponse.ok(result))

  defp emit_result(false, result) do
    IO.puts("audit #{result.run_id}: #{result.verdict}")
    Enum.each(result.findings, &IO.puts("  #{&1["status"]} #{&1["check"]}: #{&1["message"]}"))
  end

  defp emit_error(true, error), do: IO.puts(JsonResponse.error(error))
  defp emit_error(false, error), do: IO.puts(:stderr, Exception.message(error))

  defp audit_error(code, message) do
    %Sykli.Error{code: code, type: :validation, message: message, hints: [], notes: []}
  end
end
