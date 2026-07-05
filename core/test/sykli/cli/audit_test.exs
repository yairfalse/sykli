defmodule Sykli.CLI.AuditTest do
  use ExUnit.Case, async: true

  alias Sykli.CLI.Audit
  alias Sykli.RunHistory

  setup do
    workdir = Path.join(System.tmp_dir!(), "sykli-audit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workdir)
    on_exit(fn -> File.rm_rf!(workdir) end)
    {:ok, workdir: workdir}
  end

  test "unknown run id returns audit.run_not_found", %{workdir: workdir} do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Audit.run(["--json", "missing"], path: workdir) == 1
      end)

    assert %{"ok" => false, "error" => %{"code" => "audit.run_not_found"}} =
             Jason.decode!(output)
  end

  test "passes when agent mandate outcome is recorded", %{workdir: workdir} do
    save_run(workdir, [
      task("build",
        contract_slice: %{
          "actor" => %{"kind" => "agent"},
          "mandate" => %{"budget" => %{"wall_clock_ms" => 1000}}
        },
        mandate_outcome: %{"status" => "kept"}
      )
    ])

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Audit.run(["--json", "run_1"], path: workdir) == 0
      end)

    assert %{"ok" => true, "data" => %{"verdict" => "pass"}} = Jason.decode!(output)
  end

  test "fails when agent mandate outcome is missing", %{workdir: workdir} do
    save_run(workdir, [
      task("build",
        contract_slice: %{
          "actor" => %{"kind" => "agent"},
          "mandate" => %{"budget" => %{"wall_clock_ms" => 1000}}
        }
      )
    ])

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Audit.run(["--json", "run_1"], path: workdir) == 1
      end)

    assert %{
             "ok" => true,
             "data" => %{
               "verdict" => "fail",
               "findings" => [%{"check" => "mandate_outcome_recorded", "status" => "fail"}]
             }
           } = Jason.decode!(output)
  end

  describe "lock findings" do
    test "run without recorded contract hash skips lock comparison and passes",
         %{workdir: workdir} do
      write_lock(workdir)
      save_run(workdir, [task("build", [])])

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Audit.run(["--json", "run_1"], path: workdir) == 0
        end)

      assert %{
               "ok" => true,
               "data" => %{
                 "verdict" => "pass",
                 "findings" => [
                   %{
                     "check" => "lock_contract_hash",
                     "status" => "skip",
                     "message" => "run has no recorded contract hash; lock comparison skipped"
                   }
                 ]
               }
             } = Jason.decode!(output)
    end

    test "matching contract hash passes", %{workdir: workdir} do
      lock = write_lock(workdir)
      save_run(workdir, [task("build", [])], contract_hash: lock["contract_hash"])

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Audit.run(["--json", "run_1"], path: workdir) == 0
        end)

      assert %{
               "ok" => true,
               "data" => %{
                 "verdict" => "pass",
                 "findings" => [%{"check" => "lock_contract_hash", "status" => "pass"}]
               }
             } = Jason.decode!(output)
    end

    test "hash mismatch fails with expected/observed details in JSON", %{workdir: workdir} do
      lock = write_lock(workdir)
      lock_hash = lock["contract_hash"]
      save_run(workdir, [task("build", [])], contract_hash: "sha256:different")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Audit.run(["--json", "run_1"], path: workdir) == 1
        end)

      assert %{
               "ok" => true,
               "data" => %{
                 "verdict" => "fail",
                 "findings" => [
                   %{
                     "check" => "lock_contract_hash",
                     "status" => "fail",
                     "details" => %{
                       "expected" => ^lock_hash,
                       "observed" => "sha256:different"
                     }
                   }
                 ]
               }
             } = Jason.decode!(output)
    end

    test "hash mismatch shows expected/observed in text output", %{workdir: workdir} do
      lock = write_lock(workdir)
      save_run(workdir, [task("build", [])], contract_hash: "sha256:different")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Audit.run(["run_1"], path: workdir) == 1
        end)

      assert output =~ "fail lock_contract_hash: lock hash does not match run"
      assert output =~ "expected: #{lock["contract_hash"]}"
      assert output =~ "observed: sha256:different"
    end
  end

  describe "corrupt run history" do
    test "corrupt manifest alongside a valid one does not hide the valid run",
         %{workdir: workdir} do
      save_run(workdir, [task("build", [])])
      # Newer than the valid manifest, so it is scanned first.
      write_manifest(workdir, "2026-07-05T00-00-00Z.json", "{not json at all")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Audit.run(["--json", "run_1"], path: workdir) == 0
        end)

      assert %{"ok" => true, "data" => %{"run_id" => "run_1", "verdict" => "pass"}} =
               Jason.decode!(output)
    end

    test "auditing the corrupt run itself reports audit.history_corrupt, not run_not_found",
         %{workdir: workdir} do
      corrupt =
        Jason.encode!(%{
          "id" => "run_bad",
          "timestamp" => "2026-07-05T00:00:00Z",
          "git_ref" => "abc",
          "git_branch" => "main",
          "tasks" => [],
          "overall" => "no_such_status_atom_sykli_audit_test"
        })

      write_manifest(workdir, "2026-07-05T00-00-00Z.json", corrupt)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Audit.run(["--json", "run_bad"], path: workdir) == 1
        end)

      assert %{"ok" => false, "error" => %{"code" => "audit.history_corrupt"}} =
               Jason.decode!(output)
    end
  end

  defp save_run(workdir, tasks, attrs \\ []) do
    RunHistory.save(
      struct!(
        RunHistory.Run,
        Keyword.merge(
          [
            id: "run_1",
            timestamp: ~U[2026-07-04 00:00:00Z],
            git_ref: "abc",
            git_branch: "main",
            tasks: tasks,
            overall: :passed
          ],
          attrs
        )
      ),
      path: workdir
    )
  end

  defp write_lock(workdir) do
    contract = %{"version" => "5", "tasks" => [%{"name" => "build", "run" => "true"}]}
    lock = Sykli.ContractLock.build(contract, "sykli.exs")
    {:ok, _} = Sykli.ContractLock.write(lock, Path.join(workdir, "sykli.lock"))
    lock
  end

  defp write_manifest(workdir, filename, contents) do
    runs_dir = Path.join([workdir, ".sykli", "runs"])
    File.mkdir_p!(runs_dir)
    File.write!(Path.join(runs_dir, filename), contents)
  end

  defp task(name, attrs) do
    struct!(
      RunHistory.TaskResult,
      Keyword.merge(
        [
          name: name,
          status: :passed,
          duration_ms: 1,
          cached: false,
          success_criteria_results: [],
          evidence_results: []
        ],
        attrs
      )
    )
  end
end
