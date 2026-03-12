defmodule Sykli.Services.CausalityServiceTest do
  use ExUnit.Case, async: true

  alias Sykli.Services.CausalityService

  describe "analyze/4 with empty failed list" do
    test "returns empty map immediately without touching git" do
      result = CausalityService.analyze([], %{}, "/nonexistent/path")
      assert result == %{}
    end

    test "returns empty map regardless of graph contents" do
      graph = %{
        "build" => %{inputs: ["src/**/*.ex"]},
        "test" => %{inputs: ["test/**/*.exs"]}
      }

      result = CausalityService.analyze([], graph, "/some/path")
      assert result == %{}
    end
  end

  describe "analyze/4 when no previous good run exists" do
    test "returns map with all failed tasks present" do
      result = CausalityService.analyze(["test"], %{}, "/nonexistent/path")
      assert Map.has_key?(result, "test")
    end

    test "each cause has changed_files and explanation keys" do
      result = CausalityService.analyze(["test"], %{}, "/nonexistent/path")
      cause = result["test"]
      assert Map.has_key?(cause, :changed_files)
      assert Map.has_key?(cause, :explanation)
    end

    test "changed_files is a list" do
      result = CausalityService.analyze(["test"], %{}, "/nonexistent/path")
      assert is_list(result["test"].changed_files)
    end

    test "explanation is a string" do
      result = CausalityService.analyze(["test"], %{}, "/nonexistent/path")
      assert is_binary(result["test"].explanation)
    end

    test "returns one entry per failed task" do
      failed = ["lint", "test", "build"]
      result = CausalityService.analyze(failed, %{}, "/nonexistent/path")
      assert map_size(result) == 3
      assert Map.has_key?(result, "lint")
      assert Map.has_key?(result, "test")
      assert Map.has_key?(result, "build")
    end

    test "explanation mentions no previous good run when git history is absent" do
      result = CausalityService.analyze(["test"], %{}, "/nonexistent/path")
      assert result["test"].explanation =~ "no previous good run"
    end
  end

  describe "analyze/4 with custom get_field" do
    test "uses provided get_field function to extract inputs" do
      # Use a get_field that always returns nil (no inputs for any task)
      graph = %{"test" => %{some_key: "value"}}

      result =
        CausalityService.analyze(["test"], graph, "/nonexistent/path",
          get_field: fn _task, _field -> nil end
        )

      assert Map.has_key?(result, "test")
      # Cause shape must still be valid
      assert is_list(result["test"].changed_files)
      assert is_binary(result["test"].explanation)
    end

    test "accepts struct-style access via custom get_field" do
      # Simulate atom-keyed struct access
      graph = %{"deploy" => %{inputs: ["infra/**"]}}

      result =
        CausalityService.analyze(["deploy"], graph, "/nonexistent/path",
          get_field: fn task, field -> Map.get(task, field) end
        )

      assert Map.has_key?(result, "deploy")
    end
  end

  describe "analyze/4 return type" do
    test "always returns a map" do
      assert is_map(CausalityService.analyze([], %{}, "/tmp"))
      assert is_map(CausalityService.analyze(["x"], %{}, "/tmp"))
    end

    test "map keys are task name strings" do
      result = CausalityService.analyze(["alpha", "beta"], %{}, "/nonexistent")
      assert Enum.all?(Map.keys(result), &is_binary/1)
    end
  end

  describe "changed_files_for_task/3" do
    test "returns empty list when task is not in graph" do
      files = CausalityService.changed_files_for_task("missing", %{}, "/nonexistent")
      assert files == []
    end

    test "returns a list" do
      files = CausalityService.changed_files_for_task("test", %{"test" => %{}}, "/nonexistent")
      assert is_list(files)
    end

    test "returns empty list when no git history available" do
      graph = %{"test" => %{inputs: ["test/**/*.exs"]}}
      files = CausalityService.changed_files_for_task("test", graph, "/nonexistent")
      assert files == []
    end
  end
end
