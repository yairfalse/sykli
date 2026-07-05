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

  test "scope violation catches edits to paths that were already dirty", %{workdir: workdir} do
    init_repo!(workdir, %{"allowed/.keep" => "", "other/file.txt" => "before\n"})
    File.write!(Path.join(workdir, "other/file.txt"), "dirty before task\n")

    task =
      task("scoped",
        command: "printf 'changed by task\\n' > other/file.txt",
        mandate: %{"scope" => ["allowed/**"]}
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                failure_semantics: %Sykli.FailureSemantics{
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

  test "deleting an in-scope file keeps the mandate", %{workdir: workdir} do
    init_repo!(workdir, %{"allowed/old.txt" => "bye\n"})

    task =
      task("deleter",
        command: "rm allowed/old.txt",
        mandate: %{"scope" => ["allowed/**"]}
      )

    assert {:ok, [%TaskResult{status: :passed, mandate_outcome: %{"status" => "kept"}}]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "renaming within scope keeps the mandate", %{workdir: workdir} do
    init_repo!(workdir, %{"allowed/a.txt" => "content\n"})

    task =
      task("renamer",
        command: "git mv allowed/a.txt allowed/b.txt",
        mandate: %{"scope" => ["allowed/**"]}
      )

    assert {:ok, [%TaskResult{status: :passed, mandate_outcome: %{"status" => "kept"}}]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "pre-existing uncommitted changes are not charged to the diff budget", %{workdir: workdir} do
    init_repo!(workdir, %{"lib/code.ex" => "line\n"})
    # 50 dirty lines before the task ever runs
    File.write!(Path.join(workdir, "lib/code.ex"), String.duplicate("changed\n", 50))

    task =
      task("frugal",
        command: "true",
        mandate: %{"budget" => %{"diff_lines" => 1}}
      )

    assert {:ok, [%TaskResult{status: :passed, mandate_outcome: %{"status" => "kept"}}]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "task's own changes still count against the diff budget", %{workdir: workdir} do
    init_repo!(workdir, %{"lib/code.ex" => "line\n"})

    task =
      task("spender",
        command: "printf 'a\\nb\\nc\\nd\\n' > lib/extra.txt",
        mandate: %{"budget" => %{"diff_lines" => 2}}
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                failure_semantics: %Sykli.FailureSemantics{reason: "mandate_budget_exceeded"},
                mandate_outcome: %{"status" => "violated"}
              }
            ]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "new files are not double-counted against the diff budget", %{workdir: workdir} do
    init_repo!(workdir, %{"lib/code.ex" => "line\n"})

    task =
      task("spender",
        command: "printf 'a\\nb\\n' > lib/extra.txt",
        mandate: %{"budget" => %{"diff_lines" => 2}}
      )

    assert {:ok, [%TaskResult{status: :passed, mandate_outcome: %{"status" => "kept"}}]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "diff budget catches edits to files that were already dirty", %{workdir: workdir} do
    init_repo!(workdir, %{"lib/code.ex" => "one\ntwo\nthree\n"})
    File.write!(Path.join(workdir, "lib/code.ex"), "dirty\nbefore\ntask\n")

    task =
      task("spender",
        command: "printf 'changed\\nby\\ntask\\n' > lib/code.ex",
        mandate: %{"budget" => %{"diff_lines" => 0}}
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                failure_semantics: %Sykli.FailureSemantics{reason: "mandate_budget_exceeded"},
                mandate_outcome: %{"status" => "violated"}
              }
            ]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "failing task still records a kept mandate outcome", %{workdir: workdir} do
    init_repo!(workdir, %{"allowed/.keep" => ""})

    task =
      task("failing-kept",
        command: "printf x > allowed/out.txt && exit 3",
        mandate: %{"scope" => ["allowed/**"]}
      )

    assert {:error, [%TaskResult{status: :failed, mandate_outcome: %{"status" => "kept"}}]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "failing task that also violated scope records a violated outcome", %{workdir: workdir} do
    init_repo!(workdir, %{"allowed/.keep" => ""})

    task =
      task("failing-violated",
        command: "mkdir -p other && printf x > other/file.txt && exit 3",
        mandate: %{"scope" => ["allowed/**"]}
      )

    assert {:error, [%TaskResult{status: :failed, mandate_outcome: %{"status" => "violated"}}]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "git breakage during the task fails closed as unverified", %{workdir: workdir} do
    init_repo!(workdir, %{"allowed/.keep" => ""})

    task =
      task("git-breaker",
        command: "rm -rf .git",
        mandate: %{"scope" => ["allowed/**"]}
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                failure_semantics: %Sykli.FailureSemantics{
                  reason: "mandate_verification_failed"
                },
                mandate_outcome: %{"status" => "unverified"}
              }
            ]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "scope mandate in a non-git workdir is unsupported", %{workdir: workdir} do
    task =
      task("no-git",
        command: "true",
        mandate: %{"scope" => ["allowed/**"]}
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                failure_semantics: %Sykli.FailureSemantics{reason: "mandate_requires_git"},
                mandate_outcome: %{"status" => "unsupported"}
              }
            ]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell
             )
  end

  test "parallel sibling writes are not charged to a mandated task", %{workdir: workdir} do
    init_repo!(workdir, %{"allowed/.keep" => ""})

    mandated =
      task("scoped-writer",
        command: "printf x > allowed/mine.txt",
        mandate: %{"scope" => ["allowed/**"]}
      )

    sibling =
      struct!(Task,
        name: "noisy-sibling",
        command: "mkdir -p elsewhere && printf y > elsewhere/theirs.txt",
        container: nil,
        depends_on: [],
        services: [],
        outputs: %{},
        task_inputs: [],
        success_criteria: [],
        evidence_required: []
      )

    graph = %{mandated.name => mandated, sibling.name => sibling}

    assert {:ok, results} =
             Executor.run([mandated, sibling], graph,
               target: Local,
               workdir: workdir,
               containerless_runtime: Sykli.Runtime.Shell,
               max_parallel: 2
             )

    mandated_result = Enum.find(results, &(&1.name == "scoped-writer"))
    assert %TaskResult{status: :passed, mandate_outcome: %{"status" => "kept"}} = mandated_result
  end

  defp init_repo!(workdir, files) do
    git!(workdir, ["init"])

    Enum.each(files, fn {rel_path, content} ->
      abs = Path.join(workdir, rel_path)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, content)
    end)

    git!(workdir, ["add", "."])
    git!(workdir, ["commit", "-m", "init"])
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
