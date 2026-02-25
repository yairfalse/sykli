defmodule Sykli.ContextTest do
  use ExUnit.Case, async: true

  alias Sykli.Context
  alias Sykli.Graph
  alias Sykli.RunHistory
  alias Sykli.RunHistory.{Run, TaskResult}

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
      {:ok, graph} =
        parse_graph([
          %{"name" => "test", "command" => "mix test"}
        ])

      assert :ok = Context.generate(graph, nil, workdir)
      assert File.exists?(Path.join(workdir, ".sykli/context.json"))
    end

    test "includes pipeline information", %{workdir: workdir} do
      {:ok, graph} =
        parse_graph([
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
      {:ok, graph} =
        parse_graph([
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
      {:ok, graph} =
        parse_graph([
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
      {:ok, graph} =
        parse_graph([
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
      {:ok, graph} =
        parse_graph([
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
      {:ok, graph} =
        parse_graph([
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
      {:ok, graph} =
        parse_graph([
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
      {:ok, graph} =
        parse_graph([
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
      {:ok, graph} =
        parse_graph([
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
      {:ok, graph} =
        parse_graph([
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
      {:ok, graph} =
        parse_graph([
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

  describe "project context" do
    test "includes project name from directory basename", %{workdir: workdir} do
      {:ok, graph} = parse_graph([%{"name" => "test", "command" => "mix test"}])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert context["project"]["name"] == Path.basename(workdir)
      assert context["project"]["path"] == Path.expand(workdir)
    end

    test "detects languages from marker files", %{workdir: workdir} do
      # Create marker files
      File.write!(Path.join(workdir, "mix.exs"), "")
      File.write!(Path.join(workdir, "package.json"), "")
      File.write!(Path.join(workdir, "tsconfig.json"), "")

      {:ok, graph} = parse_graph([%{"name" => "test", "command" => "mix test"}])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert "elixir" in context["project"]["languages"]
      assert "javascript" in context["project"]["languages"]
      assert "typescript" in context["project"]["languages"]
      assert context["project"]["languages"] == Enum.sort(context["project"]["languages"])
    end

    test "detects SDK type from sykli file", %{workdir: workdir} do
      File.write!(Path.join(workdir, "sykli.go"), "")

      {:ok, graph} = parse_graph([%{"name" => "test", "command" => "go test"}])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert context["project"]["sdk"] == "go"
    end

    test "returns empty languages when no markers found", %{workdir: workdir} do
      {:ok, graph} = parse_graph([%{"name" => "test", "command" => "echo ok"}])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert context["project"]["languages"] == []
    end

    test "detects languages in subdirectories", %{workdir: workdir} do
      # Monorepo layout: core/mix.exs, sdk/go/go.mod
      File.mkdir_p!(Path.join(workdir, "core"))
      File.write!(Path.join([workdir, "core", "mix.exs"]), "")
      File.mkdir_p!(Path.join([workdir, "sdk", "go"]))
      File.write!(Path.join([workdir, "sdk", "go", "go.mod"]), "")

      {:ok, graph} = parse_graph([%{"name" => "test", "command" => "echo ok"}])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert "elixir" in context["project"]["languages"]
      assert "go" in context["project"]["languages"]
      assert context["project"]["languages"] == Enum.sort(context["project"]["languages"])
    end

    test "deduplicates languages from multiple Python markers", %{workdir: workdir} do
      File.write!(Path.join(workdir, "pyproject.toml"), "")
      File.write!(Path.join(workdir, "setup.py"), "")
      File.write!(Path.join(workdir, "requirements.txt"), "")

      {:ok, graph} = parse_graph([%{"name" => "test", "command" => "pytest"}])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert context["project"]["languages"] == ["python"]
    end
  end

  describe "pipeline parallelism and duration" do
    test "computes parallelism from execution levels", %{workdir: workdir} do
      # Two independent tasks (level 0) + one dependent (level 1)
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "format", "command" => "mix format --check"},
          %{"name" => "test", "command" => "mix test", "depends_on" => ["lint", "format"]}
        ])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      # lint and format run in parallel (level 0) = parallelism 2
      assert context["pipeline"]["parallelism"] == 2
    end

    test "computes estimated_duration_ms from history hints", %{workdir: workdir} do
      {:ok, graph} =
        parse_graph([
          %{
            "name" => "lint",
            "command" => "mix credo",
            "history_hint" => %{"avg_duration_ms" => 2000}
          },
          %{
            "name" => "test",
            "command" => "mix test",
            "depends_on" => ["lint"],
            "history_hint" => %{"avg_duration_ms" => 5000}
          }
        ])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      # Level 0: lint (2000ms), Level 1: test (5000ms) → total = 7000ms
      assert context["pipeline"]["estimated_duration_ms"] == 7000
    end

    test "uses 1000ms default for tasks without duration hints", %{workdir: workdir} do
      {:ok, graph} =
        parse_graph([
          %{"name" => "test", "command" => "mix test"}
        ])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert context["pipeline"]["estimated_duration_ms"] == 1000
      assert context["pipeline"]["parallelism"] == 1
    end
  end

  describe "health context" do
    test "omits health section when no run history exists", %{workdir: workdir} do
      {:ok, graph} = parse_graph([%{"name" => "test", "command" => "mix test"}])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      refute Map.has_key?(context, "health")
    end

    test "computes health from run history", %{workdir: workdir} do
      # Create run history
      save_run(workdir, :passed, ~U[2026-02-20 10:00:00Z], [
        {"test", :passed, 3000},
        {"lint", :passed, 1000}
      ])

      save_run(workdir, :failed, ~U[2026-02-19 10:00:00Z], [
        {"test", :failed, 4000},
        {"lint", :passed, 1000}
      ])

      {:ok, graph} = parse_graph([%{"name" => "test", "command" => "mix test"}])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert context["health"]["recent_runs"] == 2
      assert context["health"]["success_rate"] == 0.5
      assert context["health"]["avg_duration_ms"] == 4500
      assert context["health"]["last_success"] == "2026-02-20T10:00:00Z"
    end

    test "detects flaky tasks", %{workdir: workdir} do
      save_run(workdir, :passed, ~U[2026-02-20 10:00:00Z], [
        {"test", :passed, 3000},
        {"e2e", :passed, 5000}
      ])

      save_run(workdir, :failed, ~U[2026-02-19 10:00:00Z], [
        {"test", :passed, 3000},
        {"e2e", :failed, 5000}
      ])

      {:ok, graph} = parse_graph([%{"name" => "test", "command" => "mix test"}])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert context["health"]["flaky_tasks"] == ["e2e"]
    end

    test "omits last_success when no passing runs exist", %{workdir: workdir} do
      save_run(workdir, :failed, ~U[2026-02-20 10:00:00Z], [
        {"test", :failed, 3000}
      ])

      {:ok, graph} = parse_graph([%{"name" => "test", "command" => "mix test"}])

      :ok = Context.generate(graph, nil, workdir)
      context = read_context(workdir)

      assert context["health"]["success_rate"] == 0.0
      refute Map.has_key?(context["health"], "last_success")
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

  defp save_run(workdir, overall, timestamp, task_results) do
    tasks =
      Enum.map(task_results, fn {name, status, duration_ms} ->
        %TaskResult{name: name, status: status, duration_ms: duration_ms}
      end)

    run = %Run{
      id: "run-#{:erlang.unique_integer([:positive])}",
      timestamp: timestamp,
      git_ref: "abc123",
      git_branch: "main",
      tasks: tasks,
      overall: overall
    }

    RunHistory.save(run, path: workdir)
  end
end
