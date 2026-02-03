defmodule Sykli.Graph.Task.SemanticTest do
  use ExUnit.Case, async: true

  alias Sykli.Graph.Task.Semantic

  describe "from_map/1" do
    test "creates empty semantic from nil" do
      assert %Semantic{covers: [], intent: nil, criticality: nil} = Semantic.from_map(nil)
    end

    test "parses full semantic map" do
      map = %{
        "covers" => ["src/auth/*", "lib/session.ex"],
        "intent" => "Unit tests for auth",
        "criticality" => "high"
      }

      semantic = Semantic.from_map(map)

      assert semantic.covers == ["src/auth/*", "lib/session.ex"]
      assert semantic.intent == "Unit tests for auth"
      assert semantic.criticality == :high
    end

    test "parses criticality levels" do
      assert %Semantic{criticality: :high} = Semantic.from_map(%{"criticality" => "high"})
      assert %Semantic{criticality: :medium} = Semantic.from_map(%{"criticality" => "medium"})
      assert %Semantic{criticality: :low} = Semantic.from_map(%{"criticality" => "low"})
      assert %Semantic{criticality: nil} = Semantic.from_map(%{"criticality" => "invalid"})
    end
  end

  describe "to_map/1" do
    test "serializes semantic to map" do
      semantic = %Semantic{
        covers: ["src/*"],
        intent: "Test coverage",
        criticality: :high
      }

      map = Semantic.to_map(semantic)

      assert map["covers"] == ["src/*"]
      assert map["intent"] == "Test coverage"
      assert map["criticality"] == "high"
    end

    test "excludes nil and empty values" do
      semantic = %Semantic{covers: [], intent: nil, criticality: nil}
      map = Semantic.to_map(semantic)

      refute Map.has_key?(map, "covers")
      refute Map.has_key?(map, "intent")
      refute Map.has_key?(map, "criticality")
    end
  end

  describe "covers_any?/2" do
    test "returns false when no covers defined" do
      semantic = %Semantic{covers: []}
      refute Semantic.covers_any?(semantic, ["src/file.ex"])
    end

    test "matches exact paths" do
      semantic = %Semantic{covers: ["src/auth.ex"]}
      assert Semantic.covers_any?(semantic, ["src/auth.ex"])
      refute Semantic.covers_any?(semantic, ["src/other.ex"])
    end

    test "matches glob patterns" do
      semantic = %Semantic{covers: ["src/auth/*"]}
      assert Semantic.covers_any?(semantic, ["src/auth/login.ex"])
      refute Semantic.covers_any?(semantic, ["src/other/file.ex"])
    end

    test "matches double-star patterns" do
      semantic = %Semantic{covers: ["src/**/*.ex"]}
      assert Semantic.covers_any?(semantic, ["src/deep/nested/file.ex"])
    end
  end

  describe "critical?/1" do
    test "returns true for high criticality" do
      assert Semantic.critical?(%Semantic{criticality: :high})
    end

    test "returns false for other criticality levels" do
      refute Semantic.critical?(%Semantic{criticality: :medium})
      refute Semantic.critical?(%Semantic{criticality: :low})
      refute Semantic.critical?(%Semantic{criticality: nil})
    end
  end
end
