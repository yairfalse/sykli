defmodule Sykli.ContractSliceTest do
  use ExUnit.Case, async: true

  alias Sykli.ContractSlice
  alias Sykli.Graph
  alias Sykli.SuccessCriteria.Result

  test "projects task contract metadata without command or output" do
    task =
      parse_task(%{
        "version" => "3",
        "tasks" => [
          %{
            "name" => "test",
            "command" => "mix test",
            "task_type" => "test",
            "semantic" => %{
              "intent" => "Verify API behavior",
              "covers" => ["lib/api/**"],
              "criticality" => "high"
            },
            "ai_hooks" => %{"on_fail" => "analyze", "select" => "smart"},
            "provides" => [%{"name" => "verified-api", "value" => "yes"}],
            "needs" => ["deps-built"],
            "success_criteria" => [%{"type" => "exit_code", "equals" => 0}],
            "container" => "hexpm/elixir:latest",
            "workdir" => "apps/api",
            "timeout" => 60,
            "requires" => ["linux"]
          }
        ]
      })

    slice = ContractSlice.from_task(task)

    assert slice["kind"] == "task"
    assert slice["task_type"] == "test"
    assert slice["semantic"]["intent"] == "Verify API behavior"
    assert slice["semantic"]["criticality"] == "high"
    assert slice["ai_hooks"] == %{"on_fail" => "analyze", "select" => "smart"}
    assert slice["provides"] == [%{"name" => "verified-api", "value" => "yes"}]
    assert slice["needs"] == ["deps-built"]
    assert slice["success_criteria"] == [%{"type" => "exit_code", "equals" => 0}]
    assert slice["target"]["container"] == "hexpm/elixir:latest"
    assert slice["target"]["workdir"] == "apps/api"
    assert slice["target"]["timeout_seconds"] == 60
    assert slice["target"]["requires"] == ["linux"]
    refute Map.has_key?(slice, "command")
  end

  test "projects legacy raw-map task contract metadata" do
    slice =
      ContractSlice.from_task(%{
        kind: :task,
        task_type: "test",
        semantic: %{intent: "Verify API behavior", criticality: :high},
        ai_hooks: %{on_fail: :analyze},
        provides: [%{name: :verified_api, value: "yes"}],
        needs: [:deps_built],
        success_criteria: [%{type: "exit_code", equals: 0}],
        container: "hexpm/elixir:latest",
        workdir: "apps/api",
        timeout: 60,
        requires: [:linux]
      })

    assert slice["kind"] == "task"
    assert slice["task_type"] == "test"
    assert slice["semantic"] == %{"intent" => "Verify API behavior", "criticality" => "high"}
    assert slice["ai_hooks"] == %{"on_fail" => "analyze"}
    assert slice["provides"] == [%{"name" => "verified_api", "value" => "yes"}]
    assert slice["needs"] == ["deps_built"]
    assert slice["success_criteria"] == [%{"type" => "exit_code", "equals" => 0}]
    assert slice["target"]["container"] == "hexpm/elixir:latest"
    assert slice["target"]["requires"] == ["linux"]
  end

  test "projects actor and truncated mandate scope" do
    scope = Enum.map(1..25, &"lib/#{&1}.ex")

    task =
      parse_task(%{
        "version" => "5",
        "tasks" => [
          %{
            "name" => "implement",
            "command" => "mix test",
            "actor" => %{"kind" => "agent", "id" => "codex"},
            "mandate" => %{"scope" => scope},
            "success_criteria" => [%{"type" => "exit_code", "equals" => 0}],
            "evidence_required" => [
              %{"type" => "file", "name" => "junit", "ref_pattern" => "junit.xml"}
            ]
          }
        ]
      })

    slice = ContractSlice.from_task(task)

    assert slice["actor"] == %{"kind" => "agent", "id" => "codex"}
    assert slice["mandate"]["scope"] == Enum.take(scope, 20)
    assert slice["mandate"]["scope_count"] == 25
  end

  test "projects review and gate metadata when declared" do
    review =
      parse_task(%{
        "version" => "3",
        "tasks" => [
          %{
            "name" => "review-api",
            "kind" => "review",
            "primitive" => "api_breakage",
            "agent" => "reviewer",
            "context" => ["lib/api.ex"],
            "deterministic" => true
          }
        ]
      })

    gate =
      parse_task(%{
        "version" => "3",
        "tasks" => [
          %{
            "name" => "approve",
            "kind" => "gate",
            "gate" => %{"strategy" => "env", "timeout" => 30, "env_var" => "APPROVE_DEPLOY"}
          }
        ]
      })

    assert ContractSlice.from_task(review)["review"] == %{
             "primitive" => "api_breakage",
             "agent" => "reviewer",
             "context" => ["lib/api.ex"],
             "deterministic" => true
           }

    assert ContractSlice.from_task(gate)["gate"] == %{
             "strategy" => "env",
             "timeout" => 30,
             "env_var" => "APPROVE_DEPLOY"
           }
  end

  test "serializes and decodes success criteria results" do
    results = [
      %Result{
        index: 0,
        type: "exit_code",
        status: :failed,
        message: "expected exit code 0, got 1",
        evidence: %{"actual" => 1},
        target: "local"
      }
    ]

    assert [
             %{
               "index" => 0,
               "type" => "exit_code",
               "status" => "failed",
               "message" => "expected exit code 0, got 1",
               "evidence" => %{"actual" => 1},
               "target" => "local"
             }
           ] = ContractSlice.success_criteria_results(results)

    assert [%Result{status: :failed, type: "exit_code"}] =
             ContractSlice.success_criteria_results_from_maps(
               ContractSlice.success_criteria_results(results)
             )
  end

  test "decodes unknown persisted success criteria status as unknown" do
    assert [%Result{status: :unknown}] =
             ContractSlice.success_criteria_results_from_maps([
               %{"type" => "exit_code", "status" => "future_status"}
             ])

    assert [%Result{status: :unknown}] =
             ContractSlice.success_criteria_results_from_maps([
               %{"type" => "exit_code"}
             ])
  end

  defp parse_task(pipeline) do
    {:ok, graph} = pipeline |> Jason.encode!() |> Graph.parse()
    graph |> Map.values() |> hd()
  end
end
