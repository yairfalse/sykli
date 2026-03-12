defmodule Sykli.Services.PredictiveWarningsTest do
  use ExUnit.Case, async: true

  alias Sykli.Services.PredictiveWarnings
  alias Sykli.Graph.Task.HistoryHint

  describe "scan/1 with empty graph" do
    test "returns empty list for empty map" do
      assert PredictiveWarnings.scan(%{}) == []
    end
  end

  describe "scan/1 with tasks lacking history_hint" do
    test "ignores tasks with no history_hint field" do
      graph = %{
        "lint" => %{name: "lint", command: "mix credo"},
        "test" => %{name: "test", command: "mix test"}
      }

      assert PredictiveWarnings.scan(graph) == []
    end

    test "ignores tasks where history_hint is nil" do
      graph = %{
        "build" => %{name: "build", history_hint: nil}
      }

      assert PredictiveWarnings.scan(graph) == []
    end
  end

  describe "scan/1 flaky task detection" do
    test "emits :flaky warning when flaky=true and pass_rate < 0.80" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{flaky: true, pass_rate: 0.70}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      assert length(warnings) == 1

      [w] = warnings
      assert w.task == "test"
      assert w.type == :flaky
      assert is_binary(w.message)
      assert w.message =~ "test"
      assert w.message =~ "flaky"
    end

    test "includes pass rate percentage in flaky warning message" do
      graph = %{
        "unit" => %{
          name: "unit",
          history_hint: %HistoryHint{flaky: true, pass_rate: 0.60}
        }
      }

      [w] = PredictiveWarnings.scan(graph)
      assert w.message =~ "60%"
    end

    test "does not warn when pass_rate is exactly 0.80" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{flaky: true, pass_rate: 0.80}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      flaky_warnings = Enum.filter(warnings, &(&1.type == :flaky))
      assert flaky_warnings == []
    end

    test "does not warn when pass_rate is above 0.80" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{flaky: true, pass_rate: 0.95}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      flaky_warnings = Enum.filter(warnings, &(&1.type == :flaky))
      assert flaky_warnings == []
    end

    test "does not warn when flaky=false even with low pass_rate" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{flaky: false, pass_rate: 0.50}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      flaky_warnings = Enum.filter(warnings, &(&1.type == :flaky))
      assert flaky_warnings == []
    end

    test "does not warn when pass_rate is nil" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{flaky: true, pass_rate: nil}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      flaky_warnings = Enum.filter(warnings, &(&1.type == :flaky))
      assert flaky_warnings == []
    end
  end

  describe "scan/1 failing streak detection" do
    test "emits :failing_streak warning when streak <= -3" do
      graph = %{
        "deploy" => %{
          name: "deploy",
          history_hint: %HistoryHint{streak: -3}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      streak_warnings = Enum.filter(warnings, &(&1.type == :failing_streak))
      assert length(streak_warnings) == 1

      [w] = streak_warnings
      assert w.task == "deploy"
      assert w.type == :failing_streak
      assert is_binary(w.message)
      assert w.message =~ "deploy"
    end

    test "includes failure count in streak warning message" do
      graph = %{
        "build" => %{
          name: "build",
          history_hint: %HistoryHint{streak: -4}
        }
      }

      [w | _] = PredictiveWarnings.scan(graph)
      assert w.message =~ "4"
    end

    test "emits warning for streak of -2 (at threshold)" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{streak: -2}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      streak_warnings = Enum.filter(warnings, &(&1.type == :failing_streak))
      assert length(streak_warnings) == 1
    end

    test "does not warn when streak is -1" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{streak: -1}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      streak_warnings = Enum.filter(warnings, &(&1.type == :failing_streak))
      assert streak_warnings == []
    end

    test "does not warn for positive streak (passing streak)" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{streak: 5}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      streak_warnings = Enum.filter(warnings, &(&1.type == :failing_streak))
      assert streak_warnings == []
    end

    test "does not warn when streak is 0" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{streak: 0}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      streak_warnings = Enum.filter(warnings, &(&1.type == :failing_streak))
      assert streak_warnings == []
    end
  end

  describe "scan/1 increasing duration trend detection" do
    test "emits :duration_increasing warning when duration_trend is :increasing" do
      graph = %{
        "integration" => %{
          name: "integration",
          history_hint: %HistoryHint{duration_trend: :increasing}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      trend_warnings = Enum.filter(warnings, &(&1.type == :duration_increasing))
      assert length(trend_warnings) == 1

      [w] = trend_warnings
      assert w.task == "integration"
      assert w.type == :duration_increasing
      assert is_binary(w.message)
      assert w.message =~ "integration"
      assert w.message =~ "duration"
    end

    test "does not warn when duration_trend is :stable" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{duration_trend: :stable}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      trend_warnings = Enum.filter(warnings, &(&1.type == :duration_increasing))
      assert trend_warnings == []
    end

    test "does not warn when duration_trend is :decreasing" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{duration_trend: :decreasing}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      trend_warnings = Enum.filter(warnings, &(&1.type == :duration_increasing))
      assert trend_warnings == []
    end

    test "does not warn when duration_trend is nil" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{duration_trend: nil}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      trend_warnings = Enum.filter(warnings, &(&1.type == :duration_increasing))
      assert trend_warnings == []
    end
  end

  describe "scan/1 multiple warnings per task" do
    test "can emit both :flaky and :failing_streak for the same task" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{flaky: true, pass_rate: 0.50, streak: -3}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      types = Enum.map(warnings, & &1.type)
      assert :flaky in types
      assert :failing_streak in types
    end

    test "can emit all three warning types for a single task" do
      graph = %{
        "e2e" => %{
          name: "e2e",
          history_hint: %HistoryHint{
            flaky: true,
            pass_rate: 0.40,
            streak: -5,
            duration_trend: :increasing
          }
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      types = Enum.map(warnings, & &1.type) |> MapSet.new()
      assert MapSet.member?(types, :flaky)
      assert MapSet.member?(types, :failing_streak)
      assert MapSet.member?(types, :duration_increasing)
    end
  end

  describe "scan/1 warning shape" do
    test "every warning has :task, :type, and :message keys" do
      graph = %{
        "test" => %{
          name: "test",
          history_hint: %HistoryHint{flaky: true, pass_rate: 0.60, streak: -3}
        }
      }

      warnings = PredictiveWarnings.scan(graph)
      assert length(warnings) > 0

      Enum.each(warnings, fn w ->
        assert Map.has_key?(w, :task)
        assert Map.has_key?(w, :type)
        assert Map.has_key?(w, :message)
        assert is_binary(w.task)
        assert is_atom(w.type)
        assert is_binary(w.message)
      end)
    end

    test "warning task name matches the task key in graph" do
      graph = %{
        "my_task" => %{
          name: "my_task",
          history_hint: %HistoryHint{flaky: true, pass_rate: 0.50}
        }
      }

      [w | _] = PredictiveWarnings.scan(graph)
      assert w.task == "my_task"
    end
  end

  describe "scan/1 multi-task graphs" do
    test "only returns warnings for tasks that qualify" do
      graph = %{
        "lint" => %{name: "lint", history_hint: %HistoryHint{flaky: false, pass_rate: 1.0}},
        "test" => %{name: "test", history_hint: %HistoryHint{flaky: true, pass_rate: 0.60}},
        "build" => %{name: "build", command: "make"}
      }

      warnings = PredictiveWarnings.scan(graph)
      assert Enum.all?(warnings, &(&1.task == "test"))
    end

    test "aggregates warnings from multiple qualifying tasks" do
      graph = %{
        "unit" => %{name: "unit", history_hint: %HistoryHint{flaky: true, pass_rate: 0.50}},
        "e2e" => %{name: "e2e", history_hint: %HistoryHint{streak: -4}}
      }

      warnings = PredictiveWarnings.scan(graph)
      task_names = Enum.map(warnings, & &1.task) |> MapSet.new()
      assert MapSet.member?(task_names, "unit")
      assert MapSet.member?(task_names, "e2e")
    end
  end

  describe "print_warnings/1" do
    test "returns :ok for empty list without crashing" do
      assert PredictiveWarnings.print_warnings([]) == :ok
    end

    test "returns :ok when warnings are present" do
      warnings = [
        %{task: "test", type: :flaky, message: "test is flaky (60% pass rate)"}
      ]

      assert PredictiveWarnings.print_warnings(warnings) == :ok
    end

    test "returns :ok for multiple warnings" do
      warnings = [
        %{task: "test", type: :flaky, message: "test is flaky (70% pass rate)"},
        %{task: "build", type: :failing_streak, message: "build has failed 3 runs in a row"},
        %{task: "e2e", type: :duration_increasing, message: "e2e duration is trending upward"}
      ]

      assert PredictiveWarnings.print_warnings(warnings) == :ok
    end
  end
end
