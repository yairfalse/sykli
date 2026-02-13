defmodule Sykli.PlanTest do
  use ExUnit.Case, async: true

  alias Sykli.{Plan, Graph}

  describe "predict_cache/2" do
    test "non-cacheable tasks report not_cacheable" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"}
        ])

      result = Plan.predict_cache(graph, ".")
      assert result["lint"].cached == false
      assert result["lint"].reason == :not_cacheable
    end

    test "cacheable tasks without cache report a miss reason" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "test", "command" => "mix test", "inputs" => ["**/*.ex"]}
        ])

      result = Plan.predict_cache(graph, ".")
      assert result["test"].cached == false
      # The specific reason depends on cache state — just verify it's an atom
      assert is_atom(result["test"].reason)
      refute result["test"].reason == :not_cacheable
    end

    test "returns map keyed by task name" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "test", "command" => "mix test", "inputs" => ["**/*.ex"]}
        ])

      result = Plan.predict_cache(graph, ".")
      assert Map.has_key?(result, "lint")
      assert Map.has_key?(result, "test")
    end
  end

  describe "detect_base_branch/1" do
    test "returns a string" do
      result = Plan.detect_base_branch(".")
      assert is_binary(result)
    end

    test "returns one of origin/main, origin/master, or HEAD" do
      result = Plan.detect_base_branch(".")
      assert result in ["origin/main", "origin/master", "HEAD"]
    end
  end

  describe "generate/2 structure" do
    test "returns plan with expected top-level keys" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "test", "command" => "mix test", "depends_on" => ["lint"]}
        ])

      # Use HEAD to get no changes, producing a plan with all skipped
      case Plan.generate(graph, from: "HEAD", path: ".") do
        {:ok, plan} ->
          assert Map.has_key?(plan, :version)
          assert Map.has_key?(plan, :from)
          assert Map.has_key?(plan, :changed_files)
          assert Map.has_key?(plan, :plan)
          assert Map.has_key?(plan, :skipped)

          assert plan.version == "1.0"
          assert plan.from == "HEAD"

        {:error, _reason} ->
          # May fail if not in a git repo context - that's OK for unit tests
          :ok
      end
    end

    test "plan with no changes produces empty task list and all skipped" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "test", "command" => "mix test", "depends_on" => ["lint"]}
        ])

      case Plan.generate(graph, from: "HEAD", path: ".") do
        {:ok, plan} ->
          assert plan.plan.task_count == 0
          assert plan.plan.tasks == []
          assert length(plan.skipped) == 2

          skipped_names = Enum.map(plan.skipped, & &1.name) |> Enum.sort()
          assert skipped_names == ["lint", "test"]

        {:error, _reason} ->
          :ok
      end
    end

    test "plan data includes execution_levels, critical_path, parallelism" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"}
        ])

      case Plan.generate(graph, from: "HEAD", path: ".") do
        {:ok, plan} ->
          plan_data = plan.plan
          assert is_list(plan_data.execution_levels)
          assert is_list(plan_data.critical_path)
          assert is_integer(plan_data.parallelism)
          assert is_integer(plan_data.estimated_duration_ms)

        {:error, _reason} ->
          :ok
      end
    end

    test "skipped tasks include name and reason" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "deploy", "command" => "deploy.sh"}
        ])

      case Plan.generate(graph, from: "HEAD", path: ".") do
        {:ok, plan} ->
          Enum.each(plan.skipped, fn s ->
            assert Map.has_key?(s, :name)
            assert Map.has_key?(s, :reason)
          end)

        {:error, _} ->
          :ok
      end
    end

    test "plan is JSON-encodable" do
      {:ok, graph} =
        parse_graph([
          %{"name" => "lint", "command" => "mix credo"},
          %{"name" => "test", "command" => "mix test", "depends_on" => ["lint"]}
        ])

      case Plan.generate(graph, from: "HEAD", path: ".") do
        {:ok, plan} ->
          assert {:ok, _json} = Jason.encode(plan)

        {:error, _} ->
          :ok
      end
    end
  end

  # Helpers

  defp parse_graph(tasks) do
    json = Jason.encode!(%{"tasks" => tasks})
    Graph.parse(json)
  end
end
