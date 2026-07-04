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

  defp save_run(workdir, tasks) do
    RunHistory.save(
      %RunHistory.Run{
        id: "run_1",
        timestamp: ~U[2026-07-04 00:00:00Z],
        git_ref: "abc",
        git_branch: "main",
        tasks: tasks,
        overall: :passed
      },
      path: workdir
    )
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
