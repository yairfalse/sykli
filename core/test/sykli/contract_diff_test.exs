defmodule Sykli.ContractDiffTest do
  use ExUnit.Case, async: true

  alias Sykli.ContractDiff

  @base %{
    "version" => "4",
    "tasks" => [
      %{
        "name" => "test",
        "command" => "mix test",
        "task_type" => "test",
        "criticality" => "high",
        "success_criteria" => [%{"type" => "exit_code", "equals" => 0}],
        "evidence_required" => [
          %{"type" => "file", "name" => "coverage", "ref_pattern" => "coverage.out"}
        ]
      },
      %{"name" => "gate", "gate" => %{"strategy" => "manual"}}
    ]
  }

  test "unchanged contract has no changes" do
    assert ContractDiff.classify(@base, @base) == []
  end

  test "success_criteria removed is weakening and added is strengthening" do
    without = update_task(@base, "test", &Map.put(&1, "success_criteria", []))

    assert [%{direction: :weakening, field: "success_criteria"}] =
             only(ContractDiff.classify(@base, without), "success_criteria")

    assert [%{direction: :strengthening, field: "success_criteria"}] =
             only(ContractDiff.classify(without, @base), "success_criteria")
  end

  test "evidence_required removed is weakening and added is strengthening" do
    without = update_task(@base, "test", &Map.put(&1, "evidence_required", []))

    assert [%{direction: :weakening, field: "evidence_required"}] =
             only(ContractDiff.classify(@base, without), "evidence_required")

    assert [%{direction: :strengthening, field: "evidence_required"}] =
             only(ContractDiff.classify(without, @base), "evidence_required")
  end

  test "criticality lowered is weakening" do
    changed = update_task(@base, "test", &Map.put(&1, "criticality", "medium"))

    assert Enum.any?(
             ContractDiff.classify(@base, changed),
             &match?(%{direction: :weakening, field: "criticality"}, &1)
           )
  end

  test "gate removed is weakening and gate added is strengthening" do
    without_gate = Map.put(@base, "tasks", [List.first(@base["tasks"])])

    assert Enum.any?(
             ContractDiff.classify(@base, without_gate),
             &match?(%{direction: :weakening, kind: :task_removed}, &1)
           )

    assert Enum.any?(
             ContractDiff.classify(without_gate, @base),
             &match?(%{direction: :strengthening, kind: :task_added}, &1)
           )
  end

  test "condition added to unconditional task is weakening" do
    changed = update_task(@base, "test", &Map.put(&1, "condition", "branch == main"))

    assert Enum.any?(
             ContractDiff.classify(@base, changed),
             &match?(%{direction: :weakening, field: "condition"}, &1)
           )
  end

  test "task removed is weakening and task added is neutral" do
    without = %{"version" => "4", "tasks" => []}

    assert Enum.any?(
             ContractDiff.classify(@base, without),
             &match?(%{direction: :weakening, kind: :task_removed}, &1)
           )

    assert Enum.any?(
             ContractDiff.classify(without, @base),
             &match?(%{direction: :neutral, task: "test", kind: :task_added}, &1)
           )
  end

  test "command deps and env changes are neutral" do
    changed =
      @base
      |> update_task("test", fn task ->
        task
        |> Map.put("command", "mix test --failed")
        |> Map.put("depends_on", ["build"])
        |> Map.put("env", %{"MIX_ENV" => "test"})
      end)

    changes = ContractDiff.classify(@base, changed)
    assert Enum.any?(changes, &match?(%{direction: :neutral, field: "command"}, &1))
    assert Enum.any?(changes, &match?(%{direction: :neutral, field: "depends_on"}, &1))
    assert Enum.any?(changes, &match?(%{direction: :neutral, field: "env"}, &1))
  end

  describe "mandate changes" do
    @mandate %{
      "scope" => ["lib/**"],
      "budget" => %{"diff_lines" => 200, "wall_clock_ms" => 900_000},
      "capabilities" => %{"network" => false}
    }

    defp with_mandate(contract, mandate) do
      Map.update!(contract, "tasks", fn tasks ->
        Enum.map(tasks, fn
          %{"name" => "test"} = task -> Map.put(task, "mandate", mandate)
          task -> task
        end)
      end)
    end

    test "mandate removed is weakening and added is strengthening" do
      mandated = with_mandate(@base, @mandate)

      assert [%{kind: :mandate_removed, direction: :weakening}] =
               ContractDiff.classify(mandated, @base)

      assert [%{kind: :mandate_added, direction: :strengthening}] =
               ContractDiff.classify(@base, mandated)
    end

    test "scope widening is weakening, narrowing is strengthening" do
      narrow = with_mandate(@base, @mandate)
      wide = with_mandate(@base, %{@mandate | "scope" => ["lib/**", "docs/**"]})

      assert [%{kind: :scope_widened, direction: :weakening, field: "mandate.scope"}] =
               ContractDiff.classify(narrow, wide)

      assert [%{kind: :scope_narrowed, direction: :strengthening}] =
               ContractDiff.classify(wide, narrow)
    end

    test "scope replacement counts as widening" do
      before_ = with_mandate(@base, @mandate)
      replaced = with_mandate(@base, %{@mandate | "scope" => ["everything/**"]})

      assert [%{kind: :scope_widened, direction: :weakening}] =
               ContractDiff.classify(before_, replaced)
    end

    test "budget raised or removed is weakening, lowered or added is strengthening" do
      base = with_mandate(@base, @mandate)

      raised =
        with_mandate(@base, put_in(@mandate, ["budget", "diff_lines"], 500))

      removed =
        with_mandate(@base, Map.update!(@mandate, "budget", &Map.delete(&1, "diff_lines")))

      assert [%{kind: :budget_raised, direction: :weakening}] =
               ContractDiff.classify(base, raised)

      assert [%{kind: :budget_lowered, direction: :strengthening}] =
               ContractDiff.classify(raised, base)

      assert [%{kind: :budget_removed, direction: :weakening}] =
               ContractDiff.classify(base, removed)

      assert [%{kind: :budget_added, direction: :strengthening}] =
               ContractDiff.classify(removed, base)
    end

    test "flipping network denial is directional; true vs absent is not" do
      denied = with_mandate(@base, @mandate)
      allowed = with_mandate(@base, %{@mandate | "capabilities" => %{"network" => true}})
      unconstrained = with_mandate(@base, Map.delete(@mandate, "capabilities"))

      assert [%{kind: :network_allowed, direction: :weakening}] =
               ContractDiff.classify(denied, allowed)

      assert [%{kind: :network_denied, direction: :strengthening}] =
               ContractDiff.classify(allowed, denied)

      assert [%{kind: :network_allowed, direction: :weakening}] =
               ContractDiff.classify(denied, unconstrained)

      assert ContractDiff.classify(allowed, unconstrained) == []
    end

    test "actor change is neutral" do
      with_actor =
        Map.update!(@base, "tasks", fn tasks ->
          Enum.map(tasks, fn
            %{"name" => "test"} = task ->
              Map.put(task, "actor", %{"kind" => "agent", "id" => "claude"})

            task ->
              task
          end)
        end)

      assert [%{direction: :neutral, field: "actor"}] =
               ContractDiff.classify(@base, with_actor)
    end
  end

  test "classify fixture against itself is empty" do
    for path <- Path.wildcard("../tests/conformance/cases/*.json") do
      assert {:ok, contract} = path |> File.read!() |> Jason.decode()
      assert ContractDiff.classify(contract, contract) == []
    end
  end

  defp update_task(contract, name, fun) do
    Map.update!(contract, "tasks", fn tasks ->
      Enum.map(tasks, fn
        %{"name" => ^name} = task -> fun.(task)
        task -> task
      end)
    end)
  end

  defp only(changes, field), do: Enum.filter(changes, &(&1.field == field))
end
