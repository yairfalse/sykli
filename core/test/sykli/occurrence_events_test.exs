defmodule Sykli.OccurrenceEventsTest do
  @moduledoc """
  Tests occurrence event construction and JSON serialization round-trips
  for all 12 FALSE Protocol event types.

  Complements OccurrenceTest which focuses on enrichment and persistence.
  """
  use ExUnit.Case, async: true

  alias Sykli.Occurrence
  alias Sykli.Occurrence.Serializer

  # ─────────────────────────────────────────────────────────────────────────────
  # ci.run.started
  # ─────────────────────────────────────────────────────────────────────────────

  describe "run_started/4" do
    test "constructs ci.run.started with correct fields" do
      occ = Occurrence.run_started("run-1", "/app", ["lint", "test"])

      assert %Occurrence{} = occ
      assert occ.type == "ci.run.started"
      assert occ.severity == :info
      assert occ.run_id == "run-1"
      assert occ.protocol_version == "1.0"
      assert occ.source == "sykli"
      assert is_binary(occ.id)
      assert %DateTime{} = occ.timestamp
      assert occ.data.project_path == "/app"
      assert occ.data.tasks == ["lint", "test"]
      assert occ.data.task_count == 2
    end

    test "propagates trace context from opts" do
      occ =
        Occurrence.run_started("run-1", "/app", ["test"],
          trace_id: "abc123",
          span_id: "span-1",
          chain_id: "chain-1"
        )

      assert occ.context["trace_id"] == "abc123"
      assert occ.context["span_id"] == "span-1"
      assert occ.context["chain_id"] == "chain-1"
    end

    test "JSON round-trip preserves key fields" do
      occ = Occurrence.run_started("run-rt", "/project", ["build", "test", "deploy"])

      json = Serializer.to_json(occ)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "ci.run.started"
      assert decoded["severity"] == "info"
      assert decoded["protocol_version"] == "1.0"
      assert decoded["source"] == "sykli"
      assert decoded["id"] == occ.id
      assert decoded["context"]["labels"]["sykli.run_id"] == "run-rt"
      assert decoded["data"]["project_path"] == "/project"
      assert decoded["data"]["tasks"] == ["build", "test", "deploy"]
      assert decoded["data"]["task_count"] == 3
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ci.run.passed / ci.run.failed
  # ─────────────────────────────────────────────────────────────────────────────

  describe "run_completed/3 JSON serialization" do
    test "ci.run.passed round-trip" do
      occ = Occurrence.run_completed("run-pass", :ok)

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["type"] == "ci.run.passed"
      assert decoded["outcome"] == "success"
      assert decoded["severity"] == "info"
      assert decoded["data"]["outcome"] == "success"
    end

    test "ci.run.failed round-trip" do
      occ = Occurrence.run_completed("run-fail", {:error, :task_failed})

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["type"] == "ci.run.failed"
      assert decoded["outcome"] == "failure"
      assert decoded["severity"] == "error"
      assert decoded["data"]["outcome"] == "failure"
      assert decoded["data"]["error"] == "task_failed"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ci.task.started
  # ─────────────────────────────────────────────────────────────────────────────

  describe "task_started/3" do
    test "constructs ci.task.started with correct fields" do
      occ = Occurrence.task_started("run-2", "lint")

      assert %Occurrence{} = occ
      assert occ.type == "ci.task.started"
      assert occ.severity == :info
      assert occ.run_id == "run-2"
      assert occ.data.task_name == "lint"
      assert occ.outcome == nil
    end

    test "JSON round-trip preserves key fields" do
      occ = Occurrence.task_started("run-ts", "compile")

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["type"] == "ci.task.started"
      assert decoded["data"]["task_name"] == "compile"
      assert decoded["context"]["labels"]["sykli.run_id"] == "run-ts"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ci.task.completed
  # ─────────────────────────────────────────────────────────────────────────────

  describe "task_completed/4" do
    test "constructs success occurrence" do
      occ = Occurrence.task_completed("run-3", "test", :ok)

      assert occ.type == "ci.task.completed"
      assert occ.severity == :info
      assert occ.data.task_name == "test"
      assert occ.data.outcome == :success
      assert occ.data.error == nil
    end

    test "constructs failure occurrence with error severity" do
      occ = Occurrence.task_completed("run-3", "build", {:error, :compile_error})

      assert occ.type == "ci.task.completed"
      assert occ.severity == :error
      assert occ.data.task_name == "build"
      assert occ.data.outcome == :failure
      assert occ.data.error == :compile_error
    end

    test "JSON round-trip for success" do
      occ = Occurrence.task_completed("run-tc", "test", :ok)

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["type"] == "ci.task.completed"
      assert decoded["data"]["task_name"] == "test"
      assert decoded["data"]["outcome"] == "success"
      refute Map.has_key?(decoded, "outcome")
    end

    test "JSON round-trip for failure" do
      occ = Occurrence.task_completed("run-tc", "build", {:error, :exit_1})

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["data"]["outcome"] == "failure"
      assert decoded["data"]["error"] == "exit_1"
      assert decoded["severity"] == "error"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ci.task.output
  # ─────────────────────────────────────────────────────────────────────────────

  describe "task_output/4" do
    test "constructs ci.task.output with correct fields" do
      occ = Occurrence.task_output("run-4", "test", "....OK\n")

      assert occ.type == "ci.task.output"
      assert occ.severity == :info
      assert occ.data.task_name == "test"
      assert occ.data.output == "....OK\n"
    end

    test "JSON round-trip preserves output" do
      occ = Occurrence.task_output("run-to", "build", "compiling 42 files\n")

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["type"] == "ci.task.output"
      assert decoded["data"]["task_name"] == "build"
      assert decoded["data"]["output"] == "compiling 42 files\n"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ci.task.cached
  # ─────────────────────────────────────────────────────────────────────────────

  describe "task_cached/4" do
    test "constructs ci.task.cached with cache key" do
      occ = Occurrence.task_cached("run-5", "lint", "sha256:abc123")

      assert occ.type == "ci.task.cached"
      assert occ.severity == :info
      assert occ.data.task_name == "lint"
      assert occ.data.cache_key == "sha256:abc123"
      assert occ.data.cache_key_version == "2"
    end

    test "constructs ci.task.cached without cache key" do
      occ = Occurrence.task_cached("run-5", "lint")

      assert occ.data.cache_key == nil
    end

    test "JSON round-trip preserves cache key" do
      occ = Occurrence.task_cached("run-tca", "format", "sha256:deadbeef")

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["type"] == "ci.task.cached"
      assert decoded["data"]["task_name"] == "format"
      assert decoded["data"]["cache_key"] == "sha256:deadbeef"
      assert decoded["data"]["cache_key_version"] == "2"
    end

    test "JSON round-trip preserves cache_key_version" do
      occ = Occurrence.task_cached("run-tcv", "lint", "sha256:deadbeef")

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["data"]["cache_key_version"] == "2"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ci.task.skipped
  # ─────────────────────────────────────────────────────────────────────────────

  describe "task_skipped/4" do
    test "constructs ci.task.skipped for condition_not_met" do
      occ = Occurrence.task_skipped("run-6", "deploy", :condition_not_met)

      assert occ.type == "ci.task.skipped"
      assert occ.severity == :info
      assert occ.data.task_name == "deploy"
      assert occ.data.reason == :condition_not_met
    end

    test "constructs ci.task.skipped for dependency_failed" do
      occ = Occurrence.task_skipped("run-6", "test", :dependency_failed)

      assert occ.data.reason == :dependency_failed
    end

    test "JSON round-trip preserves reason" do
      occ = Occurrence.task_skipped("run-tsk", "deploy", :condition_not_met)

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["type"] == "ci.task.skipped"
      assert decoded["data"]["task_name"] == "deploy"
      assert decoded["data"]["reason"] == "condition_not_met"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ci.task.retrying
  # ─────────────────────────────────────────────────────────────────────────────

  describe "task_retrying/5" do
    test "constructs ci.task.retrying with correct fields" do
      occ = Occurrence.task_retrying("run-7", "flaky-test", 2, 3)

      assert occ.type == "ci.task.retrying"
      assert occ.severity == :warning
      assert occ.data.task_name == "flaky-test"
      assert occ.data.attempt == 2
      assert occ.data.max_attempts == 3
      assert occ.data.error == nil
    end

    test "includes error from opts" do
      occ = Occurrence.task_retrying("run-7", "flaky", 1, 3, error: "timeout")

      assert occ.data.error == "timeout"
    end

    test "JSON round-trip preserves retry fields" do
      occ = Occurrence.task_retrying("run-tr", "integration", 2, 5, error: "flaky network")

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["type"] == "ci.task.retrying"
      assert decoded["severity"] == "warning"
      assert decoded["data"]["task_name"] == "integration"
      assert decoded["data"]["attempt"] == 2
      assert decoded["data"]["max_attempts"] == 5
      assert decoded["data"]["error"] == "flaky network"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ci.cache.miss
  # ─────────────────────────────────────────────────────────────────────────────

  describe "cache_miss/5" do
    test "constructs ci.cache.miss with all fields" do
      occ = Occurrence.cache_miss("run-8", "build", "sha256:abc", "key_changed")

      assert occ.type == "ci.cache.miss"
      assert occ.severity == :info
      assert occ.data.task_name == "build"
      assert occ.data.cache_key == "sha256:abc"
      assert occ.data.reason == "key_changed"
      assert occ.data.cache_key_version == "2"
    end

    test "constructs ci.cache.miss with minimal fields" do
      occ = Occurrence.cache_miss("run-8", "test")

      assert occ.data.task_name == "test"
      assert occ.data.cache_key == nil
      assert occ.data.reason == nil
    end

    test "JSON round-trip preserves fields" do
      occ = Occurrence.cache_miss("run-cm", "lint", "sha256:ff", "no_entry")

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["type"] == "ci.cache.miss"
      assert decoded["data"]["task_name"] == "lint"
      assert decoded["data"]["cache_key"] == "sha256:ff"
      assert decoded["data"]["reason"] == "no_entry"
      assert decoded["data"]["cache_key_version"] == "2"
    end

    test "JSON round-trip preserves cache_key_version" do
      occ = Occurrence.cache_miss("run-cmv", "lint", "sha256:ff", "no_entry")

      decoded = occ |> Serializer.to_json() |> Jason.decode!()

      assert decoded["data"]["cache_key_version"] == "2"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ci.gate.waiting
  # ─────────────────────────────────────────────────────────────────────────────

  describe "gate_waiting/6" do
    test "constructs ci.gate.waiting with correct fields" do
      occ = Occurrence.gate_waiting("run-9", "prod-deploy", :manual, "Approve?", 3600)

      assert occ.type == "ci.gate.waiting"
      assert occ.severity == :info
      assert occ.run_id == "run-9"
      assert occ.data.gate_name == "prod-deploy"
      assert occ.data.strategy == :manual
      assert occ.data.message == "Approve?"
      assert occ.data.timeout == 3600
    end

    test "JSON round-trip via Serializer.to_map" do
      occ = Occurrence.gate_waiting("run-gw", "staging", :manual, "Deploy to staging?", 1800)

      map = Serializer.to_map(occ)

      assert map["type"] == "ci.gate.waiting"
      assert map["data"]["gate_name"] == "staging"
      assert map["data"]["strategy"] == :manual
      assert map["data"]["message"] == "Deploy to staging?"
      assert map["data"]["timeout"] == 1800
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ci.gate.resolved
  # ─────────────────────────────────────────────────────────────────────────────

  describe "gate_resolved/6" do
    test "constructs ci.gate.resolved approved with info severity" do
      occ = Occurrence.gate_resolved("run-10", "prod-deploy", :approved, "alice", 120_000)

      assert occ.type == "ci.gate.resolved"
      assert occ.severity == :info
      assert occ.data.gate_name == "prod-deploy"
      assert occ.data.outcome == :approved
      assert occ.data.approver == "alice"
      assert occ.data.duration_ms == 120_000
    end

    test "denied gate gets warning severity" do
      occ = Occurrence.gate_resolved("run-10", "prod-deploy", :denied, "bob", 5000)

      assert occ.severity == :warning
      assert occ.data.outcome == :denied
    end

    test "timed_out gate gets warning severity" do
      occ = Occurrence.gate_resolved("run-10", "prod-deploy", :timed_out, nil, 3_600_000)

      assert occ.severity == :warning
      assert occ.data.outcome == :timed_out
      assert occ.data.approver == nil
    end

    test "JSON round-trip via Serializer.to_map" do
      occ = Occurrence.gate_resolved("run-gr", "staging", :approved, "carol", 60_000)

      map = Serializer.to_map(occ)

      assert map["type"] == "ci.gate.resolved"
      assert map["data"]["gate_name"] == "staging"
      assert map["data"]["outcome"] == :approved
      assert map["data"]["approver"] == "carol"
      assert map["data"]["duration_ms"] == 60_000
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Cross-cutting: shared struct invariants
  # ─────────────────────────────────────────────────────────────────────────────

  describe "shared struct invariants" do
    test "all factory functions produce Occurrence structs with required envelope fields" do
      occurrences = [
        Occurrence.run_started("r", "/app", ["t"]),
        Occurrence.run_completed("r", :ok),
        Occurrence.run_completed("r", {:error, :fail}),
        Occurrence.task_started("r", "t"),
        Occurrence.task_completed("r", "t", :ok),
        Occurrence.task_completed("r", "t", {:error, :e}),
        Occurrence.task_output("r", "t", "out"),
        Occurrence.task_cached("r", "t", "key"),
        Occurrence.task_skipped("r", "t", :condition_not_met),
        Occurrence.task_retrying("r", "t", 1, 3),
        Occurrence.cache_miss("r", "t"),
        Occurrence.gate_waiting("r", "g", :manual, nil, 60),
        Occurrence.gate_resolved("r", "g", :approved, nil, 0)
      ]

      for occ <- occurrences do
        assert %Occurrence{} = occ
        assert is_binary(occ.id)
        assert %DateTime{} = occ.timestamp
        assert occ.protocol_version == "1.0"
        assert is_binary(occ.type)
        assert occ.source == "sykli"
        assert occ.severity in [:info, :warning, :error, :critical]
        assert occ.run_id == "r"
        assert is_map(occ.context)
      end
    end

    test "context is empty map when no trace opts provided" do
      occ = Occurrence.task_started("r", "t")
      assert occ.context == %{}
    end

    test "custom source from opts overrides default" do
      occ = Occurrence.task_started("r", "t", source: "custom-source")
      assert occ.source == "custom-source"
    end

    test "Serializer.to_map produces valid JSON-encodable map for all types" do
      occurrences = [
        Occurrence.run_started("r", "/app", ["t"]),
        Occurrence.run_completed("r", :ok),
        Occurrence.task_started("r", "t"),
        Occurrence.task_completed("r", "t", :ok),
        Occurrence.task_output("r", "t", "out"),
        Occurrence.task_cached("r", "t"),
        Occurrence.task_skipped("r", "t", :dependency_failed),
        Occurrence.task_retrying("r", "t", 1, 2),
        Occurrence.cache_miss("r", "t")
      ]

      for occ <- occurrences do
        map = Serializer.to_map(occ)
        assert is_binary(map["id"])
        assert is_binary(map["timestamp"])
        assert is_binary(map["type"])
        assert is_binary(map["source"])
        assert is_binary(map["severity"])
        assert is_map(map["context"])
        assert is_map(map["context"]["labels"])
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Serializer.to_kerto/1
  # ─────────────────────────────────────────────────────────────────────────────

  describe "Serializer.to_kerto/1" do
    test "returns {type, data_map, source} tuple" do
      occ = Occurrence.task_started("run-k", "build")

      {type, data, source} = Serializer.to_kerto(occ)

      assert type == "ci.task.started"
      assert data[:task_name] == "build"
      assert source == "sykli"
    end

    test "data is a plain map (not struct) for kerto" do
      occ = Occurrence.run_started("run-k2", "/app", ["a", "b"])

      {_type, data, _source} = Serializer.to_kerto(occ)

      refute is_struct(data)
      assert is_map(data)
      assert data[:project_path] == "/app"
    end
  end
end
