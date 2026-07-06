defmodule Sykli.Services.AuditTest do
  use ExUnit.Case, async: true

  alias Sykli.RunHistory
  alias Sykli.Services.Audit

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "sykli-audit-service-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp save_run(tmp, id, contract_hash) do
    :ok =
      RunHistory.save(
        %RunHistory.Run{
          id: id,
          timestamp: ~U[2026-07-06 10:00:00Z],
          git_ref: "abc123",
          git_branch: "main",
          overall: :passed,
          contract_hash: contract_hash,
          tasks: [
            %RunHistory.TaskResult{name: "test", status: :passed, duration_ms: 10}
          ]
        },
        path: tmp
      )
  end

  defp write_lock(tmp, contract) do
    lock = Sykli.ContractLock.build(contract, "sykli.exs")
    {:ok, _bytes} = Sykli.ContractLock.write(lock, Path.join(tmp, "sykli.lock"))
    lock["contract_hash"]
  end

  test "audit/2 loads the manifest by id", %{tmp: tmp} do
    save_run(tmp, "run-1", nil)

    assert {:ok, %{run_id: "run-1", verdict: "pass"}} = Audit.audit(tmp, "run-1")
    assert {:error, :not_found} = Audit.audit(tmp, "run-missing")
  end

  test "verdict is a read-time judgment against the current lock", %{tmp: tmp} do
    contract_a = %{"version" => "1", "tasks" => [%{"name" => "test", "command" => "make test"}]}
    contract_b = %{"version" => "1", "tasks" => [%{"name" => "test", "command" => "make cheat"}]}

    hash_a = write_lock(tmp, contract_a)
    save_run(tmp, "run-1", hash_a)

    # The run matches the lock it was recorded under.
    assert {:ok, %{verdict: "pass", findings: findings}} = Audit.audit(tmp, "run-1")
    assert %{"check" => "lock_contract_hash", "status" => "pass"} = hd(findings)

    # Re-locking a different contract flips this run's verdict at read
    # time — the audit is a judgment over evidence, never a frozen fact.
    write_lock(tmp, contract_b)

    assert {:ok, %{verdict: "fail", findings: findings}} = Audit.audit(tmp, "run-1")

    assert %{
             "check" => "lock_contract_hash",
             "status" => "fail",
             "details" => %{observed: ^hash_a}
           } = hd(findings)
  end

  test "runs without a recorded contract hash skip the lock check", %{tmp: tmp} do
    write_lock(tmp, %{"version" => "1", "tasks" => [%{"name" => "t", "command" => "x"}]})
    save_run(tmp, "run-1", nil)

    assert {:ok, %{verdict: "pass", findings: findings}} = Audit.audit(tmp, "run-1")
    assert %{"check" => "lock_contract_hash", "status" => "skip"} = hd(findings)
  end
end
