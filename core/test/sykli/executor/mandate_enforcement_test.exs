defmodule Sykli.Executor.MandateEnforcementTest do
  use ExUnit.Case, async: true

  alias Sykli.Executor
  alias Sykli.Executor.TaskResult
  alias Sykli.Graph.Task
  alias Sykli.Target.Local

  setup do
    workdir = Path.join(System.tmp_dir!(), "sykli-mandate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workdir)
    on_exit(fn -> File.rm_rf!(workdir) end)
    {:ok, workdir: workdir}
  end

  test "wall_clock_ms timeout is classified as mandate policy block", %{workdir: workdir} do
    task =
      task("bounded",
        command: "sleep 1",
        mandate: %{"budget" => %{"wall_clock_ms" => 500}}
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                failure_semantics: %Sykli.FailureSemantics{
                  class: :policy_block,
                  reason: "mandate_budget_exceeded"
                },
                mandate_outcome: %{"status" => "violated"}
              }
            ]} = Executor.run([task], graph(task), target: Local, workdir: workdir)
  end

  test "network false fails before unsupported shell execution", %{workdir: workdir} do
    task =
      task("offline",
        mandate: %{"capabilities" => %{"network" => false}}
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                failure_semantics: %Sykli.FailureSemantics{
                  class: :unsupported_target,
                  reason: "mandate_network_unsupported"
                },
                mandate_outcome: %{"status" => "unsupported"}
              }
            ]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "scope violation is a policy block", %{workdir: workdir} do
    git!(workdir, ["init"])
    File.mkdir_p!(Path.join(workdir, "allowed"))
    File.write!(Path.join(workdir, "allowed/.keep"), "")
    git!(workdir, ["add", "."])
    git!(workdir, ["commit", "-m", "init"])

    task =
      task("scoped",
        command: "mkdir -p other && printf x > other/file.txt",
        mandate: %{"scope" => ["allowed/**"]}
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                failure_semantics: %Sykli.FailureSemantics{
                  class: :policy_block,
                  reason: "mandate_scope_violation"
                },
                mandate_outcome: %{"status" => "violated"}
              }
            ]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "kept mandate records outcome", %{workdir: workdir} do
    task =
      task("kept",
        mandate: %{"budget" => %{"wall_clock_ms" => 1000}}
      )

    assert {:ok, [%TaskResult{status: :passed, mandate_outcome: %{"status" => "kept"}}]} =
             Executor.run([task], graph(task), target: Local, workdir: workdir)
  end

  defp task(name, opts) do
    struct!(
      Task,
      Keyword.merge(
        [
          name: name,
          command: "echo ok",
          container: nil,
          depends_on: [],
          services: [],
          outputs: %{},
          task_inputs: [],
          success_criteria: [],
          evidence_required: [],
          actor: %{"kind" => "agent", "id" => "codex"},
          mandate: nil
        ],
        opts
      )
    )
  end

  defp graph(%Task{} = task), do: %{task.name => task}

  defp git!(workdir, args) do
    {output, status} =
      System.cmd("git", ["-C", workdir] ++ args,
        stderr_to_stdout: true,
        env: [
          {"GIT_AUTHOR_NAME", "Sykli Test"},
          {"GIT_AUTHOR_EMAIL", "test@example.invalid"},
          {"GIT_COMMITTER_NAME", "Sykli Test"},
          {"GIT_COMMITTER_EMAIL", "test@example.invalid"}
        ]
      )

    assert status == 0, output
  end
end
