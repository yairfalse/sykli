defmodule Sykli.Graph.AiNativeTest do
  use ExUnit.Case, async: true

  alias Sykli.Graph
  alias Sykli.Graph.Task

  describe "parsing AI-native fields" do
    test "parses task with semantic metadata" do
      json = ~s|{
        "tasks": [{
          "name": "test",
          "command": "mix test",
          "semantic": {
            "covers": ["lib/auth/*", "lib/session.ex"],
            "intent": "Unit tests for authentication",
            "criticality": "high"
          }
        }]
      }|

      {:ok, graph} = Graph.parse(json)
      task = graph["test"]

      assert Task.has_semantic?(task)
      assert Task.critical?(task)

      semantic = Task.semantic(task)
      assert semantic.covers == ["lib/auth/*", "lib/session.ex"]
      assert semantic.intent == "Unit tests for authentication"
      assert semantic.criticality == :high
    end

    test "parses task with AI hooks" do
      json = ~s|{
        "tasks": [{
          "name": "lint",
          "command": "mix credo",
          "ai_hooks": {
            "on_fail": "analyze",
            "select": "smart"
          }
        }]
      }|

      {:ok, graph} = Graph.parse(json)
      task = graph["lint"]

      assert Task.has_ai_hooks?(task)
      assert Task.smart_select?(task)

      hooks = Task.ai_hooks(task)
      assert hooks.on_fail == :analyze
      assert hooks.select == :smart
    end

    test "parses task with history hints" do
      json = ~s|{
        "tasks": [{
          "name": "flaky-test",
          "command": "mix test --flaky",
          "history_hint": {
            "flaky": true,
            "avg_duration_ms": 5000,
            "failure_patterns": ["timeout", "race condition"],
            "pass_rate": 0.85,
            "streak": -2
          }
        }]
      }|

      {:ok, graph} = Graph.parse(json)
      task = graph["flaky-test"]

      assert Task.flaky?(task)

      hint = Task.history_hint(task)
      assert hint.flaky == true
      assert hint.avg_duration_ms == 5000
      assert hint.failure_patterns == ["timeout", "race condition"]
      assert hint.pass_rate == 0.85
      assert hint.streak == -2
    end

    test "parses task with all AI-native fields" do
      json = ~s|{
        "tasks": [{
          "name": "full-ai-task",
          "command": "npm test",
          "semantic": {
            "covers": ["src/**/*.ts"],
            "intent": "TypeScript unit tests",
            "criticality": "medium"
          },
          "ai_hooks": {
            "on_fail": "retry",
            "select": "always"
          },
          "history_hint": {
            "flaky": false,
            "avg_duration_ms": 3200
          }
        }]
      }|

      {:ok, graph} = Graph.parse(json)
      task = graph["full-ai-task"]

      # Semantic
      assert Task.has_semantic?(task)
      assert task.semantic.intent == "TypeScript unit tests"
      assert task.semantic.criticality == :medium

      # Hooks
      assert Task.has_ai_hooks?(task)
      assert task.ai_hooks.on_fail == :retry
      assert task.ai_hooks.select == :always

      # History
      assert task.history_hint.avg_duration_ms == 3200
      refute Task.flaky?(task)
    end

    test "provides default values when AI fields are missing" do
      json = ~s|{
        "tasks": [{
          "name": "simple",
          "command": "echo hello"
        }]
      }|

      {:ok, graph} = Graph.parse(json)
      task = graph["simple"]

      refute Task.has_semantic?(task)
      refute Task.has_ai_hooks?(task)
      refute Task.critical?(task)
      refute Task.smart_select?(task)
      refute Task.flaky?(task)

      # Accessors return empty structs
      assert Task.semantic(task).covers == []
      assert Task.ai_hooks(task).on_fail == nil
      assert Task.history_hint(task).avg_duration_ms == nil
    end
  end
end
