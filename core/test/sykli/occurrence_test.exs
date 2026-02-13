defmodule Sykli.OccurrenceTest do
  use ExUnit.Case, async: true

  alias Sykli.Occurrence
  alias Sykli.Executor.TaskResult
  alias Sykli.Graph

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "occurrence_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, workdir: test_dir}
  end

  describe "generate/4" do
    test "writes occurrence.json to .sykli/", %{workdir: workdir} do
      {graph, result, meta} = simple_passing_run()

      assert :ok = Occurrence.generate(graph, result, meta, workdir)
      assert File.exists?(Path.join(workdir, ".sykli/occurrence.json"))
    end

    test "produces valid JSON", %{workdir: workdir} do
      {graph, result, meta} = simple_passing_run()

      :ok = Occurrence.generate(graph, result, meta, workdir)
      json = File.read!(Path.join(workdir, ".sykli/occurrence.json"))
      data = Jason.decode!(json)

      assert data["version"] == "1.0"
      assert data["id"] == meta.id
      assert is_binary(data["timestamp"])
    end
  end

  describe "build/4 — FALSE Protocol envelope" do
    test "sets type and severity for passing run", %{workdir: workdir} do
      {graph, result, meta} = simple_passing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      assert occurrence["outcome"] == "passed"
      assert occurrence["type"] == "ci.run.passed"
      assert occurrence["severity"] == "info"
      assert occurrence["source"] == "sykli"
    end

    test "sets type and severity for failing run", %{workdir: workdir} do
      {graph, result, meta} = simple_failing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      assert occurrence["outcome"] == "failed"
      assert occurrence["type"] == "ci.run.failed"
      assert occurrence["severity"] == "error"
    end

    test "no error block for passing run", %{workdir: workdir} do
      {graph, result, meta} = simple_passing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      refute Map.has_key?(occurrence, "error")
    end

    test "no reasoning block for passing run", %{workdir: workdir} do
      {graph, result, meta} = simple_passing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      refute Map.has_key?(occurrence, "reasoning")
    end
  end

  describe "build/4 — ci_data summary" do
    test "includes summary for passing run", %{workdir: workdir} do
      {graph, result, meta} = simple_passing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      assert occurrence["ci_data"]["summary"]["passed"] == 1
      assert occurrence["ci_data"]["summary"]["failed"] == 0
    end

    test "includes summary for failing run", %{workdir: workdir} do
      {graph, result, meta} = simple_failing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      assert occurrence["ci_data"]["summary"]["failed"] == 1
    end

    test "includes cached task count", %{workdir: workdir} do
      graph =
        parse_graph!([
          %{"name" => "lint", "command" => "mix lint"},
          %{"name" => "test", "command" => "mix test"}
        ])

      results = [
        %TaskResult{name: "lint", status: :cached, duration_ms: 0},
        %TaskResult{name: "test", status: :passed, duration_ms: 100}
      ]

      meta = run_meta()
      occurrence = Occurrence.build(graph, {:ok, results}, meta, workdir)

      assert occurrence["ci_data"]["summary"]["cached"] == 1
      assert occurrence["ci_data"]["summary"]["passed"] == 2

      lint = Enum.find(occurrence["ci_data"]["tasks"], &(&1["name"] == "lint"))
      assert lint["cached"] == true
    end
  end

  describe "build/4 — ci_data tasks" do
    test "includes task details", %{workdir: workdir} do
      {graph, result, meta} = simple_passing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)
      tasks = occurrence["ci_data"]["tasks"]

      assert length(tasks) == 1
      task = hd(tasks)
      assert task["name"] == "test"
      assert task["status"] == "passed"
      assert task["command"] == "mix test"
      assert is_integer(task["duration_ms"])
    end

    test "preserves structured errors from Sykli.Error", %{workdir: workdir} do
      {graph, result, meta} = run_with_structured_error()

      occurrence = Occurrence.build(graph, result, meta, workdir)
      task = Enum.find(occurrence["ci_data"]["tasks"], &(&1["name"] == "build"))

      assert task["status"] == "failed"
      assert task["error"]["code"] == "task_failed"
      assert task["error"]["exit_code"] == 127
      assert is_binary(task["error"]["output"])
      assert is_list(task["error"]["hints"])
      assert length(task["error"]["hints"]) > 0
    end

    test "includes blocked task error", %{workdir: workdir} do
      graph =
        parse_graph!([
          %{"name" => "build", "command" => "make"},
          %{"name" => "test", "command" => "make test", "depends_on" => ["build"]}
        ])

      results = [
        %TaskResult{
          name: "build",
          status: :failed,
          duration_ms: 100,
          error: Sykli.Error.task_failed("build", "make", 1, "error")
        },
        %TaskResult{name: "test", status: :blocked, duration_ms: 0, error: :dependency_failed}
      ]

      meta = run_meta()
      occurrence = Occurrence.build(graph, {:error, results}, meta, workdir)

      blocked = Enum.find(occurrence["ci_data"]["tasks"], &(&1["name"] == "test"))
      assert blocked["status"] == "blocked"
      assert blocked["error"]["code"] == "dependency_failed"
    end

    test "includes depends_on and blocks", %{workdir: workdir} do
      graph =
        parse_graph!([
          %{"name" => "lint", "command" => "mix lint"},
          %{"name" => "test", "command" => "mix test", "depends_on" => ["lint"]},
          %{"name" => "build", "command" => "mix build", "depends_on" => ["test"]}
        ])

      results = [
        %TaskResult{name: "lint", status: :passed, duration_ms: 50},
        %TaskResult{name: "test", status: :passed, duration_ms: 100},
        %TaskResult{name: "build", status: :passed, duration_ms: 200}
      ]

      meta = run_meta()
      occurrence = Occurrence.build(graph, {:ok, results}, meta, workdir)

      test_task = Enum.find(occurrence["ci_data"]["tasks"], &(&1["name"] == "test"))
      assert test_task["depends_on"] == ["lint"]
      assert test_task["blocks"] == ["build"]
    end

    test "includes semantic covers", %{workdir: workdir} do
      graph =
        parse_graph!([
          %{
            "name" => "auth-test",
            "command" => "mix test",
            "semantic" => %{"covers" => ["lib/auth/*"]}
          }
        ])

      results = [
        %TaskResult{name: "auth-test", status: :passed, duration_ms: 100}
      ]

      meta = run_meta()
      occurrence = Occurrence.build(graph, {:ok, results}, meta, workdir)

      task = hd(occurrence["ci_data"]["tasks"])
      assert task["covers"] == ["lib/auth/*"]
    end
  end

  describe "build/4 — git context" do
    test "includes git context in ci_data", %{workdir: workdir} do
      {graph, result, meta} = simple_passing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      assert is_map(occurrence["ci_data"]["git"])
      assert Map.has_key?(occurrence["ci_data"]["git"], "sha")
      assert Map.has_key?(occurrence["ci_data"]["git"], "branch")
    end
  end

  describe "build/4 — error block" do
    test "includes error block for failed run", %{workdir: workdir} do
      {graph, result, meta} = simple_failing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      assert is_map(occurrence["error"])
      assert is_binary(occurrence["error"]["what_failed"])
      assert occurrence["error"]["code"] != nil
    end

    test "error block has exit_code and output for task failure", %{workdir: workdir} do
      {graph, result, meta} = run_with_structured_error()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      assert occurrence["error"]["exit_code"] == 127
      assert is_binary(occurrence["error"]["output"])
    end
  end

  describe "build/4 — reasoning block" do
    test "includes reasoning for failed run", %{workdir: workdir} do
      {graph, result, meta} = simple_failing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      assert is_map(occurrence["reasoning"])
      assert is_binary(occurrence["reasoning"]["summary"])
      assert is_number(occurrence["reasoning"]["confidence"])
      assert is_map(occurrence["reasoning"]["tasks"])
      assert Map.has_key?(occurrence["reasoning"]["tasks"], "build")
    end
  end

  describe "build/4 — history block" do
    test "includes history steps for all tasks", %{workdir: workdir} do
      {graph, result, meta} = simple_passing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      assert is_map(occurrence["history"])
      assert is_list(occurrence["history"]["steps"])
      assert length(occurrence["history"]["steps"]) == 1

      step = hd(occurrence["history"]["steps"])
      assert step["description"] == "test"
      assert step["status"] == "passed"
      assert is_integer(step["duration_ms"])
    end

    test "history step includes error for failed task", %{workdir: workdir} do
      {graph, result, meta} = simple_failing_run()

      occurrence = Occurrence.build(graph, result, meta, workdir)

      step = hd(occurrence["history"]["steps"])
      assert step["status"] == "failed"
      assert is_binary(step["error"])
    end

    test "history includes total duration", %{workdir: workdir} do
      graph =
        parse_graph!([
          %{"name" => "lint", "command" => "mix lint"},
          %{"name" => "test", "command" => "mix test"}
        ])

      results = [
        %TaskResult{name: "lint", status: :passed, duration_ms: 50},
        %TaskResult{name: "test", status: :passed, duration_ms: 100}
      ]

      meta = run_meta()
      occurrence = Occurrence.build(graph, {:ok, results}, meta, workdir)

      assert occurrence["history"]["duration_ms"] == 150
    end
  end

  describe "error_to_map/1" do
    test "converts Sykli.Error struct to map" do
      error = Sykli.Error.task_failed("test", "mix test", 127, "command not found: mix")
      map = Occurrence.error_to_map(error)

      assert map["code"] == "task_failed"
      assert map["exit_code"] == 127
      assert map["output"] == "command not found: mix"
      assert is_list(map["hints"])
      assert length(map["hints"]) > 0
    end

    test "returns nil for nil" do
      assert Occurrence.error_to_map(nil) == nil
    end

    test "wraps unknown errors with inspect" do
      map = Occurrence.error_to_map({:unknown, :reason})
      assert is_binary(map["message"])
    end

    test "handles :dependency_failed atom" do
      map = Occurrence.error_to_map(:dependency_failed)
      assert map["code"] == "dependency_failed"
    end

    test "truncates long output" do
      long_output = Enum.map_join(1..300, "\n", fn i -> "line #{i}" end)
      error = Sykli.Error.task_failed("test", "mix test", 1, long_output)
      map = Occurrence.error_to_map(error)

      lines = String.split(map["output"], "\n")
      # 200 lines + 1 truncation message
      assert length(lines) == 201
      assert String.contains?(List.last(lines), "more lines")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FIXTURES
  # ─────────────────────────────────────────────────────────────────────────────

  defp simple_passing_run do
    graph = parse_graph!([%{"name" => "test", "command" => "mix test"}])

    results = [
      %TaskResult{name: "test", status: :passed, duration_ms: 3200}
    ]

    {graph, {:ok, results}, run_meta()}
  end

  defp simple_failing_run do
    graph = parse_graph!([%{"name" => "build", "command" => "make"}])

    error = Sykli.Error.task_failed("build", "make", 1, "compilation error")

    results = [
      %TaskResult{name: "build", status: :failed, duration_ms: 1500, error: error}
    ]

    {graph, {:error, results}, run_meta()}
  end

  defp run_with_structured_error do
    graph = parse_graph!([%{"name" => "build", "command" => "make"}])

    error =
      Sykli.Error.task_failed("build", "make", 127, "command not found: make", duration_ms: 1500)

    results = [
      %TaskResult{name: "build", status: :failed, duration_ms: 1500, error: error}
    ]

    {graph, {:error, results}, run_meta()}
  end

  describe "build/4 — log paths in ci_data tasks" do
    test "task with output includes log path", %{workdir: workdir} do
      graph = parse_graph!([%{"name" => "test", "command" => "mix test"}])

      results = [
        %TaskResult{name: "test", status: :passed, duration_ms: 100, output: "ok\n"}
      ]

      meta = %{id: "01ABC", timestamp: DateTime.utc_now()}
      occurrence = Occurrence.build(graph, {:ok, results}, meta, workdir)

      task = hd(occurrence["ci_data"]["tasks"])
      assert task["log"] == ".sykli/logs/01ABC/test.log"
    end

    test "task without output has no log path", %{workdir: workdir} do
      graph = parse_graph!([%{"name" => "test", "command" => "mix test"}])

      results = [
        %TaskResult{name: "test", status: :passed, duration_ms: 100, output: nil}
      ]

      meta = run_meta()
      occurrence = Occurrence.build(graph, {:ok, results}, meta, workdir)

      task = hd(occurrence["ci_data"]["tasks"])
      refute Map.has_key?(task, "log")
    end

    test "task with empty output has no log path", %{workdir: workdir} do
      graph = parse_graph!([%{"name" => "test", "command" => "mix test"}])

      results = [
        %TaskResult{name: "test", status: :passed, duration_ms: 100, output: ""}
      ]

      meta = run_meta()
      occurrence = Occurrence.build(graph, {:ok, results}, meta, workdir)

      task = hd(occurrence["ci_data"]["tasks"])
      refute Map.has_key?(task, "log")
    end

    test "task name with slash is sanitized in log path", %{workdir: workdir} do
      graph = parse_graph!([%{"name" => "sdk/go", "command" => "go test"}])

      results = [
        %TaskResult{name: "sdk/go", status: :passed, duration_ms: 50, output: "PASS\n"}
      ]

      meta = %{id: "01XYZ", timestamp: DateTime.utc_now()}
      occurrence = Occurrence.build(graph, {:ok, results}, meta, workdir)

      task = hd(occurrence["ci_data"]["tasks"])
      assert task["log"] == ".sykli/logs/01XYZ/sdk:go.log"
    end
  end

  describe "TaskResult output field" do
    test "TaskResult supports output field" do
      result = %TaskResult{
        name: "test",
        status: :passed,
        duration_ms: 100,
        output: "some output\n"
      }

      assert result.output == "some output\n"
    end

    test "TaskResult output defaults to nil" do
      result = %TaskResult{name: "test", status: :passed, duration_ms: 100}
      assert result.output == nil
    end
  end

  defp run_meta do
    %{
      id: "test-#{:erlang.unique_integer([:positive])}",
      timestamp: DateTime.utc_now()
    }
  end

  defp parse_graph!(tasks) do
    json = Jason.encode!(%{"tasks" => tasks})
    {:ok, graph} = Graph.parse(json)
    graph
  end
end
