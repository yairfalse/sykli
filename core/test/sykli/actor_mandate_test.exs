defmodule Sykli.ActorMandateTest do
  use ExUnit.Case, async: true

  alias Sykli.{Graph, Validate}

  defp pipeline(task, version \\ "5") do
    Jason.encode!(%{"version" => version, "tasks" => [task]})
  end

  defp valid_agent_task(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "implement",
        "command" => "mix test",
        "actor" => %{"kind" => "agent", "id" => "codex"},
        "mandate" => %{
          "scope" => ["core/lib/**"],
          "budget" => %{"diff_lines" => 120, "wall_clock_ms" => 60_000},
          "capabilities" => %{"network" => false}
        },
        "success_criteria" => [%{"type" => "exit_code", "equals" => 0}],
        "evidence_required" => [
          %{"type" => "file", "name" => "junit", "ref_pattern" => "junit.xml"}
        ]
      },
      overrides
    )
  end

  test "parses v5 actor and mandate declarations" do
    assert {:ok, graph} = Graph.parse(pipeline(valid_agent_task()))
    task = Map.fetch!(graph, "implement")

    assert Graph.Task.actor(task) == %{"kind" => "agent", "id" => "codex"}
    assert Graph.Task.mandate(task)["scope"] == ["core/lib/**"]
  end

  test "accepts task_type success_criteria and evidence_required in v5" do
    task = valid_agent_task(%{"task_type" => "test"})
    assert {:ok, _graph} = Graph.parse(pipeline(task))

    result = Validate.validate_json(pipeline(task))
    assert result.valid
  end

  test "rejects actor and mandate before v5" do
    task =
      valid_agent_task(%{"actor" => %{"kind" => "human"}, "mandate" => %{"scope" => ["lib/**"]}})

    assert {:error, {:actor_requires_version_5, "implement", "4"}} =
             Graph.parse(pipeline(task, "4"))

    result = Validate.validate_json(pipeline(task, "4"))
    assert Enum.any?(result.errors, &(&1.type == :actor_requires_version_5))
    assert Enum.any?(result.errors, &(&1.type == :mandate_requires_version_5))
  end

  test "rejects invalid actor shapes" do
    cases = [
      {%{"kind" => "robot"}, {:unknown_actor_kind, "implement", "robot"}},
      {%{"kind" => "agent", "id" => ""},
       {:invalid_actor, "implement", "id must be a non-empty string"}},
      {%{"id" => "codex"}, {:invalid_actor, "implement", "requires kind"}},
      {"agent", {:invalid_actor, "implement", "must be an object"}},
      {%{"kind" => "agent", "role" => "coder"},
       {:invalid_actor, "implement", "unknown keys: role"}}
    ]

    for {actor, expected} <- cases do
      assert {:error, ^expected} = Graph.parse(pipeline(valid_agent_task(%{"actor" => actor})))
    end
  end

  test "rejects actor and mandate on review nodes" do
    review = %{
      "name" => "review-code",
      "kind" => "review",
      "primitive" => "lint",
      "actor" => %{"kind" => "human"},
      "mandate" => %{"scope" => ["lib/**"]}
    }

    assert {:error, {:actor_on_review, "review-code"}} = Graph.parse(pipeline(review))

    result = Validate.validate_json(pipeline(review))
    assert Enum.any?(result.errors, &(&1.type == :actor_on_review))
    assert Enum.any?(result.errors, &(&1.type == :mandate_on_review))
  end

  test "rejects invalid mandate shapes" do
    cases = [
      {%{}, {:invalid_mandate, "implement", "requires scope"}},
      {%{"scope" => []}, {:invalid_mandate, "implement", "scope must be a non-empty array"}},
      {%{"scope" => [""]},
       {:invalid_mandate, "implement", "scope entries must be non-empty strings"}},
      {%{"scope" => ["lib/**"], "budget" => %{}},
       {:invalid_mandate, "implement", "budget must not be empty"}},
      {%{"scope" => ["lib/**"], "budget" => %{"diff_lines" => 0}},
       {:invalid_mandate, "implement", "budget.diff_lines must be a positive integer"}},
      {%{"scope" => ["lib/**"], "budget" => %{"wall_clock_ms" => "fast"}},
       {:invalid_mandate, "implement", "budget.wall_clock_ms must be a positive integer"}},
      {%{"scope" => ["lib/**"], "capabilities" => %{"network" => "yes"}},
       {:invalid_mandate, "implement", "capabilities.network must be a boolean"}},
      {%{"scope" => ["lib/**"], "capabilities" => %{"shell" => true}},
       {:invalid_mandate, "implement", "capabilities has unknown keys: shell"}},
      {%{"scope" => ["lib/**"], "extra" => true},
       {:invalid_mandate, "implement", "has unknown keys: extra"}}
    ]

    for {mandate, expected} <- cases do
      assert {:error, ^expected} =
               Graph.parse(pipeline(valid_agent_task(%{"mandate" => mandate})))
    end
  end

  test "agent actors require mandate success criteria and evidence" do
    cases = [
      {Map.delete(valid_agent_task(), "mandate"), :agent_requires_mandate},
      {Map.put(valid_agent_task(), "success_criteria", []), :agent_requires_success_criteria},
      {Map.put(valid_agent_task(), "evidence_required", []), :agent_requires_evidence_required}
    ]

    for {task, type} <- cases do
      assert {:error, {^type, "implement"}} = Graph.parse(pipeline(task))

      result = Validate.validate_json(pipeline(task))
      assert Enum.any?(result.errors, &(&1.type == type))
    end
  end

  test "formats actor and mandate errors through graph path" do
    assert Graph.format_error({:unknown_actor_kind, "implement", "robot"}) ==
             ~s(Error: Task 'implement' declares unknown actor kind "robot")

    assert Graph.format_error({:agent_requires_mandate, "implement"}) ==
             ~s(Error: Task 'implement' declares actor.kind "agent" but does not declare mandate)
  end
end
