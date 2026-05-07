defmodule Sykli.ExecutorAiHooksTest do
  use ExUnit.Case, async: true

  alias Sykli.Graph.Task.AiHooks

  describe "AiHooks struct" do
    test "on_fail: :skip is parsed" do
      hooks = AiHooks.from_map(%{"on_fail" => "skip"})
      assert hooks.on_fail == :skip
    end

    test "on_fail: :retry is parsed" do
      hooks = AiHooks.from_map(%{"on_fail" => "retry"})
      assert hooks.on_fail == :retry
    end

    test "on_fail: :analyze is parsed" do
      hooks = AiHooks.from_map(%{"on_fail" => "analyze"})
      assert hooks.on_fail == :analyze
    end

    test "select: :smart is parsed" do
      hooks = AiHooks.from_map(%{"select" => "smart"})
      assert hooks.select == :smart
    end

    test "select: :manual is parsed" do
      hooks = AiHooks.from_map(%{"select" => "manual"})
      assert hooks.select == :manual
    end

    test "select: :always is parsed" do
      hooks = AiHooks.from_map(%{"select" => "always"})
      assert hooks.select == :always
    end

    test "nil map returns defaults" do
      hooks = AiHooks.from_map(nil)
      assert hooks.on_fail == nil
      assert hooks.select == nil
    end
  end

  describe "Executor.Config struct" do
    test "has default values" do
      config = %Sykli.Executor.Config{
        target: Sykli.Target.Local,
        timeout: 300_000
      }

      assert config.max_parallel == nil
      assert config.continue_on_failure == false
      assert config.run_id == nil
    end

    test "accepts custom values" do
      config = %Sykli.Executor.Config{
        target: Sykli.Target.Local,
        timeout: 300_000,
        max_parallel: 4,
        continue_on_failure: true,
        run_id: "test-run"
      }

      assert config.max_parallel == 4
      assert config.continue_on_failure == true
      assert config.run_id == "test-run"
    end
  end

  describe "secret_refs parsing" do
    test "parses secret_refs from JSON" do
      json =
        ~s({"version":"1","tasks": [{"name": "deploy", "command": "deploy.sh", "secret_refs": [{"name": "AWS_KEY", "source": "env", "key": "AWS_ACCESS_KEY_ID"}, {"name": "DB_PASS", "source": "file", "key": "/run/secrets/db"}]}]})

      result = Sykli.Validate.validate_json(json)
      assert result.valid == true
    end

    test "graph parses secret_refs into task struct" do
      json =
        ~s({"version":"1","tasks": [{"name": "deploy", "command": "deploy.sh", "secret_refs": [{"name": "TOKEN", "source": "env", "key": "DEPLOY_TOKEN"}]}]})

      {:ok, graph} = Sykli.Graph.parse(json)
      task = Map.get(graph, "deploy")

      assert length(task.secret_refs) == 1
      [ref] = task.secret_refs
      assert ref.name == "TOKEN"
      assert ref.source == "env"
      assert ref.key == "DEPLOY_TOKEN"
    end

    test "empty secret_refs defaults to empty list" do
      json = ~s({"version":"1","tasks": [{"name": "test", "command": "echo hi"}]})

      {:ok, graph} = Sykli.Graph.parse(json)
      task = Map.get(graph, "test")

      assert task.secret_refs == []
    end
  end
end
