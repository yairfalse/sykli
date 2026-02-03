defmodule Sykli.ContextTest do
  use ExUnit.Case, async: true

  alias Sykli.Context
  alias Sykli.Graph

  @tmp_dir System.tmp_dir!()

  setup do
    # Create a unique temp directory for each test
    test_dir = Path.join(@tmp_dir, "context_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, workdir: test_dir}
  end

  describe "generate/3" do
    test "creates context.json in .sykli directory", %{workdir: workdir} do
      {:ok, graph} = parse_graph([
        %{"name" => "test", "command" => "mix test"}
      ])

      assert :ok = Context.generate(graph, nil, workdir)
      assert File.exists?(Path.join(workdir, ".sykli/context.json"))
    end

    test "includes pipeline information", %{workdir: workdir} do
      {:ok, graph} = parse_graph([
        %{"name" => "build", "command" => "mix compile"},
        %{"name" => "test", "command" => "mix test", "depends_on" => ["build"]}
      ])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert context["version"] == "1.0"
      assert context["pipeline"]["task_count"] == 2
      assert length(context["pipeline"]["tasks"]) == 2
      assert context["pipeline"]["dependencies"]["test"] == ["build"]
    end

    test "includes semantic metadata in tasks", %{workdir: workdir} do
      {:ok, graph} = parse_graph([
        %{
          "name" => "auth-test",
          "command" => "mix test",
          "semantic" => %{
            "covers" => ["lib/auth/*"],
            "intent" => "Auth tests",
            "criticality" => "high"
          }
        }
      ])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      task = Enum.find(context["pipeline"]["tasks"], &(&1["name"] == "auth-test"))
      assert task["semantic"]["covers"] == ["lib/auth/*"]
      assert task["semantic"]["intent"] == "Auth tests"
      assert task["semantic"]["criticality"] == "high"
    end

    test "includes critical_tasks list", %{workdir: workdir} do
      {:ok, graph} = parse_graph([
        %{
          "name" => "critical",
          "command" => "mix test",
          "semantic" => %{"criticality" => "high"}
        },
        %{
          "name" => "normal",
          "command" => "mix test",
          "semantic" => %{"criticality" => "low"}
        }
      ])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert "critical" in context["pipeline"]["critical_tasks"]
      refute "normal" in context["pipeline"]["critical_tasks"]
    end

    test "includes run results when provided", %{workdir: workdir} do
      {:ok, graph} = parse_graph([
        %{"name" => "test", "command" => "mix test"}
      ])

      run_result = %{
        timestamp: ~U[2024-01-15 10:30:00Z],
        outcome: :success,
        duration_ms: 1234,
        tasks: [
          %{name: "test", status: :passed, duration_ms: 1000, cached: false}
        ]
      }

      :ok = Context.generate(graph, run_result, workdir)
      context = read_context(workdir)

      assert context["last_run"]["outcome"] == "success"
      assert context["last_run"]["duration_ms"] == 1234
      assert length(context["last_run"]["tasks"]) == 1
    end
  end

  describe "generate_test_map/2" do
    test "creates test-map.json", %{workdir: workdir} do
      {:ok, graph} = parse_graph([
        %{
          "name" => "auth-test",
          "command" => "mix test",
          "semantic" => %{"covers" => ["lib/auth/*"]}
        },
        %{
          "name" => "api-test",
          "command" => "mix test",
          "semantic" => %{"covers" => ["lib/api/*"]}
        }
      ])

      :ok = Context.generate_test_map(graph, workdir)

      test_map = read_json(workdir, "test-map.json")
      assert test_map["lib/auth/*"] == ["auth-test"]
      assert test_map["lib/api/*"] == ["api-test"]
    end

    test "groups multiple tasks covering same pattern", %{workdir: workdir} do
      {:ok, graph} = parse_graph([
        %{
          "name" => "unit-test",
          "command" => "mix test",
          "semantic" => %{"covers" => ["lib/core/*"]}
        },
        %{
          "name" => "integration-test",
          "command" => "mix test",
          "semantic" => %{"covers" => ["lib/core/*"]}
        }
      ])

      :ok = Context.generate_test_map(graph, workdir)

      test_map = read_json(workdir, "test-map.json")
      assert Enum.sort(test_map["lib/core/*"]) == ["integration-test", "unit-test"]
    end
  end

  describe "tasks_for_changes/2" do
    test "returns tasks covering changed files" do
      {:ok, graph} = parse_graph([
        %{
          "name" => "auth-test",
          "command" => "mix test",
          "semantic" => %{"covers" => ["lib/auth/*"]},
          "ai_hooks" => %{"select" => "smart"}
        },
        %{
          "name" => "api-test",
          "command" => "mix test",
          "semantic" => %{"covers" => ["lib/api/*"]},
          "ai_hooks" => %{"select" => "smart"}
        }
      ])

      tasks = Context.tasks_for_changes(graph, ["lib/auth/login.ex"])

      assert "auth-test" in tasks
      refute "api-test" in tasks
    end

    test "includes non-smart tasks regardless of changes" do
      {:ok, graph} = parse_graph([
        %{
          "name" => "lint",
          "command" => "mix credo",
          "ai_hooks" => %{"select" => "always"}
        },
        %{
          "name" => "auth-test",
          "command" => "mix test",
          "semantic" => %{"covers" => ["lib/auth/*"]},
          "ai_hooks" => %{"select" => "smart"}
        }
      ])

      tasks = Context.tasks_for_changes(graph, ["lib/unrelated.ex"])

      assert "lint" in tasks
      refute "auth-test" in tasks
    end

    test "excludes manual tasks" do
      {:ok, graph} = parse_graph([
        %{
          "name" => "deploy",
          "command" => "./deploy.sh",
          "ai_hooks" => %{"select" => "manual"}
        }
      ])

      tasks = Context.tasks_for_changes(graph, ["lib/auth/login.ex"])

      refute "deploy" in tasks
    end
  end

  describe "task_to_map/1" do
    test "includes basic fields" do
      {:ok, graph} = parse_graph([
        %{
          "name" => "test",
          "command" => "mix test",
          "depends_on" => ["build"]
        }
      ])

      task = graph["test"]
      map = Context.task_to_map(task)

      assert map["name"] == "test"
      assert map["command"] == "mix test"
      assert map["depends_on"] == ["build"]
    end

    test "includes execution context when present" do
      {:ok, graph} = parse_graph([
        %{
          "name" => "test",
          "command" => "npm test",
          "container" => "node:18",
          "workdir" => "/app",
          "timeout" => 300,
          "retry" => 3
        }
      ])

      task = graph["test"]
      map = Context.task_to_map(task)

      assert map["container"] == "node:18"
      assert map["workdir"] == "/app"
      assert map["timeout"] == 300
      assert map["retry"] == 3
    end
  end

  # Helpers

  defp parse_graph(tasks) do
    json = Jason.encode!(%{"tasks" => tasks})
    Graph.parse(json)
  end

  defp read_context(workdir), do: read_json(workdir, "context.json")

  defp read_json(workdir, filename) do
    Path.join([workdir, ".sykli", filename])
    |> File.read!()
    |> Jason.decode!()
  end
end
