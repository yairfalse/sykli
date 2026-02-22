defmodule Sykli.Occurrence.SerializerTest do
  use ExUnit.Case, async: true

  alias Sykli.Occurrence
  alias Sykli.Occurrence.Serializer

  describe "to_json/1" do
    test "encodes occurrence to valid JSON string" do
      occ = Occurrence.task_started("run-1", "test")
      json = Serializer.to_json(occ)

      assert is_binary(json)
      data = Jason.decode!(json)
      assert data["type"] == "ci.task.started"
      assert data["context"]["labels"]["sykli.run_id"] == "run-1"
    end
  end

  describe "to_map/1" do
    test "converts occurrence to string-key map" do
      occ = Occurrence.task_started("run-1", "test")
      map = Serializer.to_map(occ)

      assert map["type"] == "ci.task.started"
      assert map["protocol_version"] == "1.0"
      assert map["source"] == "sykli"
      assert map["severity"] == "info"
      assert is_binary(map["id"])
      assert is_binary(map["timestamp"])
      # run_id and node are now in context.labels
      assert map["context"]["labels"]["sykli.run_id"] == "run-1"
      assert is_binary(map["context"]["labels"]["sykli.node"])
    end

    test "includes data as plain map" do
      occ = Occurrence.task_started("run-1", "test")
      map = Serializer.to_map(occ)

      # encode_data uses Map.from_struct → atom keys
      assert map["data"][:task_name] == "test"
    end

    test "omits nil fields" do
      occ = Occurrence.task_started("run-1", "test")
      map = Serializer.to_map(occ)

      refute Map.has_key?(map, "outcome")
      refute Map.has_key?(map, "error")
      refute Map.has_key?(map, "reasoning")
      refute Map.has_key?(map, "history")
    end

    test "includes outcome for run_completed" do
      occ = Occurrence.run_completed("run-1", :ok)
      map = Serializer.to_map(occ)

      assert map["outcome"] == "success"
    end

    test "includes trace_id in context when set" do
      occ = Occurrence.task_started("run-1", "test", trace_id: "trace-abc")
      map = Serializer.to_map(occ)

      assert map["context"]["trace_id"] == "trace-abc"
    end
  end

  describe "to_kerto/1" do
    test "returns {type, data, source} tuple" do
      occ = Occurrence.task_started("run-1", "test")
      {type, data, source} = Serializer.to_kerto(occ)

      assert type == "ci.task.started"
      assert data[:task_name] == "test"
      assert source == "sykli"
    end

    test "returns empty map for nil data" do
      occ = %Occurrence{
        id: "test",
        timestamp: DateTime.utc_now(),
        protocol_version: "1.0",
        type: "ci.test",
        source: "sykli",
        severity: :info,
        run_id: "run-1",
        node: node(),
        data: nil
      }

      {_type, data, _source} = Serializer.to_kerto(occ)
      assert data == %{}
    end
  end

  describe "to_ahti/3" do
    test "converts to AHTI TapioEvent format" do
      occ = Occurrence.run_started("run-1", "/project", ["test"])
      ahti = Serializer.to_ahti(occ, "prod-cluster")

      assert ahti.type == "deployment"
      assert ahti.subtype == "ci_run_started"
      assert ahti.severity == "info"
      assert ahti.cluster == "prod-cluster"
      assert ahti.labels["sykli.run_id"] == "run-1"
      assert is_binary(ahti.id)
      assert is_binary(ahti.timestamp)
    end

    test "maps run_completed passed to success outcome" do
      occ = Occurrence.run_completed("run-1", :ok)
      ahti = Serializer.to_ahti(occ, "cluster-1")

      assert ahti.outcome == "success"
      assert ahti.subtype == "ci_run_completed"
    end

    test "maps run_completed failed to failure outcome" do
      occ = Occurrence.run_completed("run-1", {:error, :task_failed})
      ahti = Serializer.to_ahti(occ, "cluster-1")

      assert ahti.outcome == "failure"
      assert ahti.severity == "error"
    end

    test "builds entities for task events" do
      occ = Occurrence.task_started("run-1", "build")
      ahti = Serializer.to_ahti(occ, "cluster-1")

      assert length(ahti.entities) == 1
      entity = hd(ahti.entities)
      assert entity.type == "container"
      assert entity.attributes["task_name"] == "build"
    end

    test "includes process_data for task_completed" do
      occ = Occurrence.task_completed("run-1", "build", :ok)
      ahti = Serializer.to_ahti(occ, "cluster-1")

      assert ahti.process_data.exit_code == 0
    end

    test "accepts options" do
      occ = Occurrence.task_started("run-1", "test")
      ahti = Serializer.to_ahti(occ, "cluster-1", namespace: "default", source: "custom")

      assert ahti.namespace == "default"
      assert ahti.source == "custom"
    end
  end

  describe "to_ahti_json/3" do
    test "returns valid JSON string" do
      occ = Occurrence.run_started("run-1", "/project", ["test"])
      json = Serializer.to_ahti_json(occ, "cluster-1")

      assert is_binary(json)
      data = Jason.decode!(json)
      assert data["type"] == "deployment"
      assert data["cluster"] == "cluster-1"
    end
  end
end
