defmodule Sykli.Executor.SuccessCriteriaEnforcementTest do
  use ExUnit.Case, async: true

  alias Sykli.Error
  alias Sykli.Executor
  alias Sykli.Executor.TaskResult
  alias Sykli.Graph.Task
  alias Sykli.SuccessCriteria.Result
  alias Sykli.Target.Local

  defmodule UnsupportedTarget do
    @behaviour Sykli.Target.Behaviour

    @impl true
    def name, do: "unsupported"

    @impl true
    def available?, do: {:ok, %{mode: :test}}

    @impl true
    def setup(opts), do: {:ok, %{workdir: Keyword.get(opts, :workdir, ".")}}

    @impl true
    def teardown(_state), do: :ok

    @impl true
    def resolve_secret(_name, _state), do: {:error, :not_found}

    @impl true
    def create_volume(_name, _opts, _state),
      do: {:ok, %{id: "unsupported", host_path: nil, reference: "unsupported"}}

    @impl true
    def artifact_path(_task, _artifact, _workdir, _state), do: "/unsupported/path"

    @impl true
    def copy_artifact(_src, _dest, _workdir, _state), do: :ok

    @impl true
    def start_services(_name, _services, _state), do: {:ok, nil}

    @impl true
    def stop_services(_info, _state), do: :ok

    @impl true
    def run_task(_task, _state, _opts), do: :ok
  end

  setup do
    workdir =
      Path.join(System.tmp_dir!(), "sykli-success-criteria-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)

    on_exit(fn -> File.rm_rf!(workdir) end)

    {:ok, workdir: workdir}
  end

  test "local target passes when file_exists criterion is satisfied", %{workdir: workdir} do
    task =
      task("produce-file",
        command: "printf ok > result.txt",
        success_criteria: [%{"type" => "file_exists", "path" => "result.txt"}]
      )

    assert {:ok, [%TaskResult{status: :passed, success_criteria_results: [result]}]} =
             Executor.run([task], graph(task), target: Local, workdir: workdir)

    assert %Result{type: "file_exists", status: :passed, target: "local"} = result
  end

  test "local target fails when command exits 0 but file_exists criterion fails", %{
    workdir: workdir
  } do
    task =
      task("missing-file",
        command: "echo done",
        success_criteria: [%{"type" => "file_exists", "path" => "missing.txt"}]
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                error: %Error{code: "success_criteria_failed"},
                success_criteria_results: [%Result{type: "file_exists", status: :failed}]
              }
            ]} = Executor.run([task], graph(task), target: Local, workdir: workdir)
  end

  test "success_criteria failure participates in retry behavior", %{workdir: workdir} do
    task =
      task("retry-criteria",
        command: "n=$(cat attempts 2>/dev/null || echo 0); n=$((n + 1)); echo $n > attempts",
        retry: 1,
        success_criteria: [%{"type" => "file_exists", "path" => "missing.txt"}]
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                error: %Error{code: "success_criteria_failed"}
              }
            ]} = Executor.run([task], graph(task), target: Local, workdir: workdir)

    assert File.read!(Path.join(workdir, "attempts")) == "2\n"
  end

  test "local target passes when file_non_empty criterion is satisfied", %{workdir: workdir} do
    task =
      task("non-empty",
        command: "printf ok > result.txt",
        success_criteria: [%{"type" => "file_non_empty", "path" => "result.txt"}]
      )

    assert {:ok, [%TaskResult{status: :passed, success_criteria_results: [result]}]} =
             Executor.run([task], graph(task), target: Local, workdir: workdir)

    assert %Result{type: "file_non_empty", status: :passed} = result
  end

  test "local target fails when file_non_empty criterion sees an empty file", %{workdir: workdir} do
    task =
      task("empty-file",
        command: "touch result.txt",
        success_criteria: [%{"type" => "file_non_empty", "path" => "result.txt"}]
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                error: %Error{code: "success_criteria_failed"},
                success_criteria_results: [%Result{type: "file_non_empty", status: :failed}]
              }
            ]} = Executor.run([task], graph(task), target: Local, workdir: workdir)
  end

  test "local target evaluates exit_code criteria after command success", %{workdir: workdir} do
    task =
      task("exit-code",
        command: "echo ok",
        success_criteria: [%{"type" => "exit_code", "equals" => 0}]
      )

    assert {:ok, [%TaskResult{status: :passed, success_criteria_results: [result]}]} =
             Executor.run([task], graph(task), target: Local, workdir: workdir)

    assert %Result{type: "exit_code", status: :passed, evidence: %{actual: 0, expected: 0}} =
             result
  end

  test "local target fails when exit_code criterion contradicts successful command", %{
    workdir: workdir
  } do
    task =
      task("wrong-exit-code",
        command: "echo ok",
        success_criteria: [%{"type" => "exit_code", "equals" => 1}]
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                error: %Error{code: "success_criteria_failed"},
                success_criteria_results: [%Result{type: "exit_code", status: :failed}]
              }
            ]} = Executor.run([task], graph(task), target: Local, workdir: workdir)
  end

  test "task command failure still fails normally and does not report criteria results", %{
    workdir: workdir
  } do
    task =
      task("command-fails",
        command: "exit 7",
        success_criteria: [%{"type" => "exit_code", "equals" => 0}]
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                error: %Error{code: "task_failed", exit_code: 7},
                success_criteria_results: []
              }
            ]} = Executor.run([task], graph(task), target: Local, workdir: workdir)
  end

  test "target without criteria evaluator fails explicitly", %{workdir: workdir} do
    task =
      task("unsupported-target",
        command: "echo ok",
        success_criteria: [%{"type" => "file_exists", "path" => "result.txt"}]
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                error: %Error{code: "unsupported_success_criteria_for_target"},
                success_criteria_results: [
                  %Result{type: "file_exists", status: :unsupported, target: "unsupported"}
                ]
              }
            ]} = Executor.run([task], graph(task), target: UnsupportedTarget, workdir: workdir)
  end

  test "local container runtime file criteria fail explicitly as unsupported", %{workdir: workdir} do
    task =
      task("container-file",
        command: "echo ok",
        container: "alpine:latest",
        success_criteria: [%{"type" => "file_exists", "path" => "result.txt"}]
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                error: %Error{code: "unsupported_success_criteria_for_target"},
                success_criteria_results: [
                  %Result{type: "file_exists", status: :unsupported, target: "local"}
                ]
              }
            ]} =
             Executor.run([task], graph(task),
               target: Local,
               workdir: workdir,
               runtime: Sykli.Runtime.Fake
             )
  end

  test "tasks without success_criteria preserve existing behavior", %{workdir: workdir} do
    task = task("plain", command: "echo ok")

    assert {:ok, [%TaskResult{status: :passed, success_criteria_results: []}]} =
             Executor.run([task], graph(task), target: Local, workdir: workdir)
  end

  test "file criteria are evaluated relative to task workdir", %{workdir: workdir} do
    File.mkdir_p!(Path.join(workdir, "subdir"))

    task =
      task("workdir-file",
        command: "printf ok > result.txt",
        workdir: "subdir",
        success_criteria: [%{"type" => "file_exists", "path" => "result.txt"}]
      )

    assert {:ok, [%TaskResult{status: :passed, success_criteria_results: [result]}]} =
             Executor.run([task], graph(task), target: Local, workdir: workdir)

    assert result.evidence.resolved_path == Path.join([workdir, "subdir", "result.txt"])
  end

  test "file criteria cannot escape the resolved task workdir", %{workdir: workdir} do
    task =
      task("escape-file",
        command: "echo ok",
        success_criteria: [%{"type" => "file_exists", "path" => "../outside.txt"}]
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                error: %Error{code: "success_criteria_failed"},
                success_criteria_results: [
                  %Result{
                    type: "file_exists",
                    status: :failed,
                    message: "path escapes task workdir"
                  }
                ]
              }
            ]} = Executor.run([task], graph(task), target: Local, workdir: workdir)
  end

  test "absolute file criteria paths fail instead of checking arbitrary host paths", %{
    workdir: workdir
  } do
    task =
      task("absolute-file",
        command: "echo ok",
        success_criteria: [%{"type" => "file_exists", "path" => "/tmp/sykli-absolute"}]
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                error: %Error{code: "success_criteria_failed"},
                success_criteria_results: [
                  %Result{
                    type: "file_exists",
                    status: :failed,
                    message: "path must be relative to task workdir"
                  }
                ]
              }
            ]} = Executor.run([task], graph(task), target: Local, workdir: workdir)
  end

  test "file criteria reject symlinks instead of following them outside workdir", %{
    workdir: workdir
  } do
    outside = Path.join(System.tmp_dir!(), "sykli-outside-#{System.unique_integer([:positive])}")
    File.write!(outside, "outside")

    on_exit(fn -> File.rm(outside) end)

    File.ln_s!(outside, Path.join(workdir, "inside-link.txt"))

    task =
      task("symlink-file",
        command: "echo ok",
        success_criteria: [%{"type" => "file_exists", "path" => "inside-link.txt"}]
      )

    assert {:error,
            [
              %TaskResult{
                status: :failed,
                error: %Error{code: "success_criteria_failed"},
                success_criteria_results: [
                  %Result{
                    type: "file_exists",
                    status: :failed,
                    message: "symlinks are not supported for success_criteria paths"
                  }
                ]
              }
            ]} = Executor.run([task], graph(task), target: Local, workdir: workdir)
  end

  defp task(name, opts) do
    struct!(
      Task,
      Keyword.merge(
        [
          name: name,
          command: "echo ok",
          depends_on: [],
          services: [],
          outputs: %{},
          task_inputs: [],
          success_criteria: []
        ],
        opts
      )
    )
  end

  defp graph(%Task{} = task), do: %{task.name => task}
end
