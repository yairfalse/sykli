defmodule Sykli.VocabularySyncTest do
  @moduledoc """
  Regression guard for contract vocabulary drift across SDKs, schema, and engine.
  """

  use ExUnit.Case, async: true

  @moduletag :regression_guard

  @repo_root Path.expand("../../..", __DIR__)

  test "task_type values are set-equal across engine, schema, and all SDKs" do
    expected = manifest_values("task_type")

    sources = %{
      "engine" => MapSet.new(Sykli.TaskType.all()),
      "schema" => schema_task_types(),
      "go" => quoted_values("sdk/go/sykli.go", ~r/TaskType\w+\s+TaskType\s+=\s+"([^"]+)"/),
      "rust" => quoted_values("sdk/rust/src/lib.rs", ~r/TaskType::\w+\s+=>\s+"([^"]+)"/),
      "typescript" =>
        quoted_values(
          "sdk/typescript/src/index.ts",
          ~r/'(build|test|lint|format|scan|package|publish|deploy|migrate|generate|verify|cleanup)'/
        ),
      "python" =>
        quoted_values(
          "sdk/python/src/sykli/__init__.py",
          ~r/"(build|test|lint|format|scan|package|publish|deploy|migrate|generate|verify|cleanup)"/
        ),
      "elixir" => atom_values("sdk/elixir/lib/sykli/task.ex", ~r/:([a-z_]+)/)
    }

    assert sources != %{}

    Enum.each(sources, fn {name, values} ->
      assert values == expected,
             "#{name} task_type values drifted:\nexpected=#{inspect(MapSet.to_list(expected))}\nactual=#{inspect(MapSet.to_list(values))}"
    end)
  end

  test "success_criteria and evidence_required type sets match schema-owned engine vocabularies" do
    assert MapSet.new(Sykli.SuccessCriteria.types()) == manifest_values("success_criteria")
    assert MapSet.new(Sykli.EvidenceRequirement.types()) == manifest_values("evidence_required")
    assert MapSet.new(Sykli.Actor.kinds()) == manifest_values("actor_kind")
    assert MapSet.new(Sykli.SuccessCriteria.types()) == schema_success_criteria_types()
    assert MapSet.new(Sykli.EvidenceRequirement.types()) == schema_evidence_required_types()
    assert MapSet.new(Sykli.Actor.kinds()) == schema_actor_kinds()
  end

  test "task_type conformance case exercises every task_type value" do
    values =
      @repo_root
      |> Path.join("tests/conformance/cases/23-task-type.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("tasks")
      |> Enum.map(&Map.fetch!(&1, "task_type"))
      |> MapSet.new()

    assert values == manifest_values("task_type")
  end

  defp manifest_values(key) do
    @repo_root
    |> Path.join("schemas/vocabulary.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!(key)
    |> MapSet.new()
  end

  defp schema_task_types do
    schema()
    |> get_in(["$defs", "task", "properties", "task_type", "enum"])
    |> MapSet.new()
  end

  defp schema_success_criteria_types do
    defs = schema() |> Map.fetch!("$defs")

    defs
    |> Map.take(["exitCodeCriterion", "fileExistsCriterion", "fileNonEmptyCriterion"])
    |> Map.values()
    |> Enum.map(&get_in(&1, ["properties", "type", "const"]))
    |> MapSet.new()
  end

  defp schema_evidence_required_types do
    schema()
    |> get_in(["$defs", "evidenceRequirement", "properties", "type", "enum"])
    |> MapSet.new()
  end

  defp schema_actor_kinds do
    schema()
    |> get_in(["$defs", "actor", "properties", "kind", "enum"])
    |> MapSet.new()
  end

  defp schema do
    @repo_root
    |> Path.join("schemas/sykli-pipeline.schema.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp quoted_values(path, regex) do
    path
    |> read_repo_file()
    |> then(&Regex.scan(regex, &1, capture: :all_but_first))
    |> Enum.map(&List.first/1)
    |> MapSet.new()
  end

  defp atom_values(path, regex) do
    path
    |> read_repo_file()
    |> then(&Regex.scan(regex, &1, capture: :all_but_first))
    |> Enum.map(&List.first/1)
    |> Enum.filter(&(&1 in Sykli.TaskType.all()))
    |> MapSet.new()
  end

  defp read_repo_file(path), do: File.read!(Path.join(@repo_root, path))
end
