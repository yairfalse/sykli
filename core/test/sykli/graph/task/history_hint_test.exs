defmodule Sykli.Graph.Task.HistoryHintTest do
  use ExUnit.Case, async: true

  alias Sykli.Graph.Task.HistoryHint

  describe "from_map/1" do
    test "creates empty hint from nil" do
      hint = HistoryHint.from_map(nil)

      assert hint.flaky == false
      assert hint.avg_duration_ms == nil
      assert hint.failure_patterns == []
      assert hint.pass_rate == nil
      assert hint.streak == 0
    end

    test "parses full hint map" do
      map = %{
        "flaky" => true,
        "avg_duration_ms" => 3200,
        "failure_patterns" => ["timeout", "connection"],
        "pass_rate" => 0.95,
        "last_failure" => "2024-01-15T10:30:00Z",
        "streak" => 5
      }

      hint = HistoryHint.from_map(map)

      assert hint.flaky == true
      assert hint.avg_duration_ms == 3200
      assert hint.failure_patterns == ["timeout", "connection"]
      assert hint.pass_rate == 0.95
      assert hint.last_failure == ~U[2024-01-15 10:30:00Z]
      assert hint.streak == 5
    end
  end

  describe "to_map/1" do
    test "serializes hint to map" do
      hint = %HistoryHint{
        flaky: true,
        avg_duration_ms: 1000,
        failure_patterns: ["error"],
        pass_rate: 0.9,
        streak: -2
      }

      map = HistoryHint.to_map(hint)

      assert map["flaky"] == true
      assert map["avg_duration_ms"] == 1000
      assert map["failure_patterns"] == ["error"]
      assert map["pass_rate"] == 0.9
      assert map["streak"] == -2
    end

    test "excludes default values" do
      hint = %HistoryHint{}
      map = HistoryHint.to_map(hint)

      assert map == %{}
    end
  end

  describe "from_history/1" do
    test "returns empty hint for empty history" do
      hint = HistoryHint.from_history([])

      assert hint.flaky == false
      assert hint.avg_duration_ms == nil
    end

    test "computes stats from results" do
      results = [
        %{status: :passed, duration_ms: 100, timestamp: ~U[2024-01-15 10:00:00Z]},
        %{status: :passed, duration_ms: 200, timestamp: ~U[2024-01-15 11:00:00Z]},
        %{status: :failed, duration_ms: 150, error: "timeout", timestamp: ~U[2024-01-15 12:00:00Z]}
      ]

      hint = HistoryHint.from_history(results)

      assert hint.flaky == true
      assert hint.avg_duration_ms == 150
      assert hint.pass_rate == 2 / 3
      assert "timeout" in hint.failure_patterns
    end

    test "computes positive streak for consecutive passes" do
      results = [
        %{status: :passed, duration_ms: 100, timestamp: ~U[2024-01-15 10:00:00Z]},
        %{status: :passed, duration_ms: 100, timestamp: ~U[2024-01-15 11:00:00Z]},
        %{status: :failed, duration_ms: 100, timestamp: ~U[2024-01-15 12:00:00Z]}
      ]

      hint = HistoryHint.from_history(results)
      assert hint.streak == 2
    end

    test "computes negative streak for consecutive failures" do
      results = [
        %{status: :failed, duration_ms: 100, timestamp: ~U[2024-01-15 10:00:00Z]},
        %{status: :failed, duration_ms: 100, timestamp: ~U[2024-01-15 11:00:00Z]},
        %{status: :passed, duration_ms: 100, timestamp: ~U[2024-01-15 12:00:00Z]}
      ]

      hint = HistoryHint.from_history(results)
      assert hint.streak == -2
    end
  end

  describe "flaky?/1" do
    test "returns true when flaky" do
      assert HistoryHint.flaky?(%HistoryHint{flaky: true})
    end

    test "returns false when not flaky" do
      refute HistoryHint.flaky?(%HistoryHint{flaky: false})
    end
  end

  describe "matches_known_failure?/2" do
    test "returns false when no patterns" do
      hint = %HistoryHint{failure_patterns: []}
      refute HistoryHint.matches_known_failure?(hint, "some error")
    end

    test "matches known patterns case-insensitively" do
      hint = %HistoryHint{failure_patterns: ["Timeout", "Connection Reset"]}

      assert HistoryHint.matches_known_failure?(hint, "TIMEOUT occurred")
      assert HistoryHint.matches_known_failure?(hint, "connection reset by peer")
      refute HistoryHint.matches_known_failure?(hint, "unknown error")
    end
  end
end
