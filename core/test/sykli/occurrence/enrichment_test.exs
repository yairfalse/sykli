defmodule Sykli.Occurrence.EnrichmentTest do
  use ExUnit.Case, async: false

  alias Sykli.Occurrence
  alias Sykli.Occurrence.Enrichment
  alias Sykli.Executor.TaskResult

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "enrichment_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, workdir: test_dir}
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ENRICH (integration of all blocks)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "enrich/4" do
    test "enriches a passing run with no error block", %{workdir: workdir} do
      occ = make_occurrence("run-pass", "ci.run.passed", "success")
      graph = %{"build" => %{command: "go build"}}

      results =
        {:ok,
         [
           %TaskResult{name: "build", status: :passed, duration_ms: 100}
         ]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)

      assert enriched.error == nil
      assert enriched.reasoning == nil
      assert is_map(enriched.history)
      assert enriched.history["steps"] != nil
      assert enriched.history["duration_ms"] == 100
      assert is_map(enriched.data)
      assert enriched.data["summary"]["passed"] == 1
      assert enriched.data["summary"]["failed"] == 0
    end

    test "enriches a failing run with error, reasoning, and history blocks", %{workdir: workdir} do
      occ = make_occurrence("run-fail", "ci.run.failed", "failure")

      graph = %{
        "test" => %{command: "mix test", depends_on: ["build"]},
        "build" => %{command: "go build"}
      }

      error = %Sykli.Error{
        code: "task_failed",
        type: :execution,
        message: "task 'test' failed",
        task: "test",
        command: "mix test",
        exit_code: 1,
        output: "1 test failed",
        hints: ["Check test output for details"],
        notes: [],
        locations: []
      }

      results =
        {:error,
         [
           %TaskResult{name: "build", status: :passed, duration_ms: 50},
           %TaskResult{name: "test", status: :failed, duration_ms: 200, error: error}
         ]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)

      # Error block present for failed run
      assert enriched.error != nil
      assert enriched.error["code"] == "task_failed"
      assert enriched.error["what_failed"] =~ "test"

      # Reasoning block present
      assert enriched.reasoning != nil
      assert enriched.reasoning["summary"] =~ "test"

      assert is_float(enriched.reasoning["confidence"]) or
               is_integer(enriched.reasoning["confidence"])

      # History block present with correct step count
      assert is_map(enriched.history)
      assert length(enriched.history["steps"]) == 2
      assert enriched.history["duration_ms"] == 250
    end

    test "handles empty results gracefully", %{workdir: workdir} do
      occ = make_occurrence("run-empty", "ci.run.passed", "success")
      enriched = Enrichment.enrich(occ, %{}, {:ok, []}, workdir)

      assert enriched.error == nil
      assert enriched.reasoning == nil
      assert enriched.history["steps"] == []
      assert enriched.history["duration_ms"] == 0
    end

    test "handles non-list executor results", %{workdir: workdir} do
      occ = make_occurrence("run-bad", "ci.run.failed", "failure")
      enriched = Enrichment.enrich(occ, %{}, :unexpected, workdir)

      assert enriched.error == nil
      assert enriched.history["steps"] == []
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ERROR BLOCK (tested through enrich)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "error block via enrich/4" do
    test "single failed task produces task-level error", %{workdir: workdir} do
      occ = make_occurrence("run-1fail", "ci.run.failed", "failure")

      error = %Sykli.Error{
        code: "task_failed",
        type: :execution,
        message: "task 'lint' failed",
        hints: ["Run linter locally first"],
        notes: [],
        locations: []
      }

      graph = %{"lint" => %{command: "eslint ."}}

      results =
        {:error, [%TaskResult{name: "lint", status: :failed, duration_ms: 300, error: error}]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)

      assert enriched.error["code"] == "task_failed"
      assert enriched.error["what_failed"] =~ "lint"
      assert enriched.error["what_failed"] =~ "eslint"
    end

    test "multiple failed tasks produce aggregate error", %{workdir: workdir} do
      occ = make_occurrence("run-2fail", "ci.run.failed", "failure")

      error1 = %Sykli.Error{
        code: "task_failed",
        type: :execution,
        message: "task 'build' failed",
        hints: [],
        notes: [],
        locations: []
      }

      error2 = %Sykli.Error{
        code: "task_failed",
        type: :execution,
        message: "task 'test' failed",
        hints: [],
        notes: [],
        locations: []
      }

      graph = %{"build" => %{command: "make"}, "test" => %{command: "make test"}}

      results =
        {:error,
         [
           %TaskResult{name: "build", status: :failed, duration_ms: 100, error: error1},
           %TaskResult{name: "test", status: :failed, duration_ms: 200, error: error2}
         ]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)

      assert enriched.error["code"] == "ci.run.failed"
      assert enriched.error["what_failed"] =~ "2 tasks failed"
      assert enriched.error["what_failed"] =~ "build"
      assert enriched.error["what_failed"] =~ "test"
    end

    test "no failed tasks produce nil error block", %{workdir: workdir} do
      occ = make_occurrence("run-ok", "ci.run.passed", "success")
      graph = %{"build" => %{command: "make"}}

      results =
        {:ok, [%TaskResult{name: "build", status: :passed, duration_ms: 50}]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)
      assert enriched.error == nil
    end

    test "errored task is treated as failure for error block", %{workdir: workdir} do
      occ = make_occurrence("run-errored", "ci.run.failed", "failure")
      graph = %{"deploy" => %{command: "kubectl apply"}}

      results =
        {:error,
         [
           %TaskResult{
             name: "deploy",
             status: :errored,
             duration_ms: 5000,
             error: %Sykli.Error{
               code: "task_timeout",
               type: :execution,
               message: "task 'deploy' timed out",
               hints: [],
               notes: [],
               locations: []
             }
           }
         ]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)
      assert enriched.error != nil
      assert enriched.error["code"] == "task_timeout"
    end

    test "dependency_failed error is handled", %{workdir: workdir} do
      occ = make_occurrence("run-dep", "ci.run.failed", "failure")
      graph = %{"test" => %{command: "make test", depends_on: ["build"]}}

      results =
        {:error,
         [
           %TaskResult{
             name: "test",
             status: :errored,
             duration_ms: 0,
             error: :dependency_failed
           }
         ]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)
      assert enriched.error != nil
      assert enriched.error["code"] == "dependency_failed"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # REASONING BLOCK (tested through enrich)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "reasoning block via enrich/4" do
    test "no failures produce nil reasoning", %{workdir: workdir} do
      occ = make_occurrence("run-ok", "ci.run.passed", "success")
      graph = %{"build" => %{command: "make"}}
      results = {:ok, [%TaskResult{name: "build", status: :passed, duration_ms: 50}]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)
      assert enriched.reasoning == nil
    end

    test "failure produces reasoning with confidence", %{workdir: workdir} do
      occ = make_occurrence("run-f", "ci.run.failed", "failure")

      error = %Sykli.Error{
        code: "task_failed",
        type: :execution,
        message: "task 'test' failed",
        hints: [],
        notes: [],
        locations: []
      }

      graph = %{"test" => %{command: "mix test"}}

      results =
        {:error, [%TaskResult{name: "test", status: :failed, duration_ms: 100, error: error}]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)

      assert enriched.reasoning["summary"] != nil
      assert enriched.reasoning["explanation"] != nil
      assert enriched.reasoning["confidence"] != nil
      # Without causality data, confidence should be low
      assert enriched.reasoning["confidence"] <= 0.5
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HISTORY BLOCK (tested through enrich)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "history block via enrich/4" do
    test "generates steps with timestamps for each task", %{workdir: workdir} do
      occ = make_occurrence("run-hist", "ci.run.passed", "success")
      graph = %{"a" => %{command: "cmd-a"}, "b" => %{command: "cmd-b"}}

      results =
        {:ok,
         [
           %TaskResult{name: "a", status: :passed, duration_ms: 100},
           %TaskResult{name: "b", status: :passed, duration_ms: 200}
         ]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)
      history = enriched.history

      assert length(history["steps"]) == 2
      assert history["duration_ms"] == 300

      [step_a, step_b] = history["steps"]
      assert step_a["action"] == "a"
      assert step_a["outcome"] == "success"
      assert step_a["duration_ms"] == 100
      assert step_a["description"] == "cmd-a"
      assert step_a["timestamp"] != nil

      assert step_b["action"] == "b"
      assert step_b["outcome"] == "success"
      assert step_b["duration_ms"] == 200
      assert step_b["description"] == "cmd-b"
    end

    test "maps status to correct outcome strings", %{workdir: workdir} do
      occ = make_occurrence("run-outcomes", "ci.run.failed", "failure")
      graph = %{}

      results =
        {:error,
         [
           %TaskResult{name: "pass", status: :passed, duration_ms: 10},
           %TaskResult{
             name: "fail",
             status: :failed,
             duration_ms: 10,
             error: %Sykli.Error{
               code: "task_failed",
               type: :execution,
               message: "failed",
               hints: [],
               notes: [],
               locations: []
             }
           },
           %TaskResult{
             name: "err",
             status: :errored,
             duration_ms: 10,
             error: %Sykli.Error{
               code: "task_timeout",
               type: :execution,
               message: "errored",
               hints: [],
               notes: [],
               locations: []
             }
           },
           %TaskResult{name: "cache", status: :cached, duration_ms: 0},
           %TaskResult{name: "skip", status: :skipped, duration_ms: 0},
           %TaskResult{name: "block", status: :blocked, duration_ms: 0, error: :dependency_failed}
         ]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)
      steps = enriched.history["steps"]

      outcomes = Enum.map(steps, & &1["outcome"])
      assert outcomes == ["success", "failure", "error", "success", "skipped", "failure"]
    end

    test "failed task step includes error info", %{workdir: workdir} do
      occ = make_occurrence("run-step-err", "ci.run.failed", "failure")
      graph = %{"test" => %{command: "mix test"}}

      error = %Sykli.Error{
        code: "task_failed",
        type: :execution,
        message: "task 'test' failed",
        hints: [],
        notes: [],
        locations: []
      }

      results =
        {:error, [%TaskResult{name: "test", status: :failed, duration_ms: 100, error: error}]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)
      step = hd(enriched.history["steps"])

      assert step["error"]["code"] == "task_failed"
      assert step["error"]["what_failed"] =~ "test"
    end

    test "step timestamps are offset from base timestamp", %{workdir: workdir} do
      occ = make_occurrence("run-ts", "ci.run.passed", "success")
      graph = %{}

      results =
        {:ok,
         [
           %TaskResult{name: "a", status: :passed, duration_ms: 1000},
           %TaskResult{name: "b", status: :passed, duration_ms: 2000}
         ]}

      enriched = Enrichment.enrich(occ, graph, results, workdir)
      [step_a, step_b] = enriched.history["steps"]

      {:ok, ts_a, _} = DateTime.from_iso8601(step_a["timestamp"])
      {:ok, ts_b, _} = DateTime.from_iso8601(step_b["timestamp"])

      diff_ms = DateTime.diff(ts_b, ts_a, :millisecond)
      assert diff_ms == 1000
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ERROR DETAIL MAP (public function)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "error_detail_map/1" do
    test "returns nil for nil input" do
      assert Enrichment.error_detail_map(nil) == nil
    end

    test "maps Sykli.Error struct to detail map" do
      error = %Sykli.Error{
        code: "task_failed",
        type: :execution,
        message: "task 'build' failed",
        exit_code: 1,
        output: "error: cannot find module",
        hints: ["Check imports"],
        notes: ["Build step"],
        locations: []
      }

      result = Enrichment.error_detail_map(error)

      assert result["code"] == "task_failed"
      assert result["message"] == "task 'build' failed"
      assert result["exit_code"] == 1
      assert result["output"] =~ "cannot find module"
      assert result["hints"] == ["Check imports"]
    end

    test "maps :dependency_failed atom" do
      result = Enrichment.error_detail_map(:dependency_failed)
      assert result["code"] == "dependency_failed"
      assert result["message"] =~ "blocked"
    end

    test "maps unknown error term" do
      result = Enrichment.error_detail_map({:some, :error})
      assert result["message"] =~ "some"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # TO_PERSISTENCE_MAP (public function)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "to_persistence_map/1" do
    test "converts occurrence struct to string-keyed map" do
      occ = make_occurrence("run-persist", "ci.run.passed", "success")
      occ = %{occ | data: %{"summary" => %{"passed" => 1}}}

      result = Enrichment.to_persistence_map(occ)

      assert result["id"] == "run-persist"
      assert result["type"] == "ci.run.passed"
      assert result["outcome"] == "success"
      assert result["protocol_version"] == "1.0"
      assert result["source"] == "sykli"
      assert result["timestamp"] != nil
      assert result["context"]["labels"]["sykli.run_id"] == "run-persist"
      assert result["data"]["summary"]["passed"] == 1
    end

    test "omits nil error, reasoning, history" do
      occ = make_occurrence("run-nil", "ci.run.passed", "success")
      result = Enrichment.to_persistence_map(occ)

      refute Map.has_key?(result, "error")
      refute Map.has_key?(result, "reasoning")
      refute Map.has_key?(result, "history")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # PERSIST (tested through enrich_and_persist for side effects)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "enrich_and_persist/4" do
    test "writes occurrence.json and per-run JSON file", %{workdir: workdir} do
      occ = make_occurrence("run-write", "ci.run.passed", "success")
      graph = %{"build" => %{command: "make"}}
      results = {:ok, [%TaskResult{name: "build", status: :passed, duration_ms: 100}]}

      assert :ok = Enrichment.enrich_and_persist(occ, graph, results, workdir)

      # Check latest occurrence.json was written
      latest = Path.join([workdir, ".sykli", "occurrence.json"])
      assert File.exists?(latest)

      {:ok, json} = File.read(latest)
      {:ok, decoded} = Jason.decode(json)
      assert decoded["id"] == "run-write"

      # Check per-run JSON file
      per_run = Path.join([workdir, ".sykli", "occurrences_json", "run-write.json"])
      assert File.exists?(per_run)

      # Check ETF file
      etf = Path.join([workdir, ".sykli", "occurrences", "run-write.etf"])
      assert File.exists?(etf)

      # Verify ETF is valid
      binary = File.read!(etf)
      decoded_etf = :erlang.binary_to_term(binary)
      assert decoded_etf["id"] == "run-write"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FIXTURES
  # ─────────────────────────────────────────────────────────────────────────────

  defp make_occurrence(run_id, type, outcome) do
    %Occurrence{
      id: run_id,
      timestamp: DateTime.utc_now(),
      protocol_version: "1.0",
      type: type,
      source: "sykli",
      severity: if(outcome == "success", do: :info, else: :error),
      outcome: outcome,
      run_id: run_id,
      node: :nonode@nohost,
      context: %{},
      data: nil,
      error: nil,
      reasoning: nil,
      history: nil
    }
  end
end
