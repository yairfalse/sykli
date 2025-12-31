defmodule Sykli.ValidateTest do
  use ExUnit.Case, async: true

  alias Sykli.Validate

  @moduletag :tmp_dir

  describe "validate/1" do
    test "returns ok for valid pipeline" do
      # Test using JSON directly (can't run Go in test env)
      json = """
      {
        "tasks": [
          {"name": "test", "command": "echo test"},
          {"name": "build", "command": "echo build", "depends_on": ["test"]}
        ]
      }
      """

      result = Validate.validate_json(json)

      assert result.valid == true
      assert result.errors == []
      assert length(result.tasks) == 2
    end

    test "returns error for missing sykli file", %{tmp_dir: tmp_dir} do
      assert {:error, :no_sdk_file} = Validate.validate(tmp_dir)
    end

    test "detects cycle in dependencies" do
      # This test uses the JSON directly since creating a real cycle
      # in Go code would fail at emit time
      json = """
      {
        "tasks": [
          {"name": "a", "command": "echo a", "depends_on": ["b"]},
          {"name": "b", "command": "echo b", "depends_on": ["a"]}
        ]
      }
      """

      result = Validate.validate_json(json)

      assert result.valid == false
      assert Enum.any?(result.errors, &(&1.type == :cycle))
    end

    test "detects missing dependency" do
      json = """
      {
        "tasks": [
          {"name": "build", "command": "echo build", "depends_on": ["nonexistent"]}
        ]
      }
      """

      result = Validate.validate_json(json)

      assert result.valid == false
      assert Enum.any?(result.errors, &(&1.type == :missing_dependency))

      error = Enum.find(result.errors, &(&1.type == :missing_dependency))
      assert error.task == "build"
      assert error.dependency == "nonexistent"
    end

    test "detects empty task name" do
      json = """
      {
        "tasks": [
          {"name": "", "command": "echo test"}
        ]
      }
      """

      result = Validate.validate_json(json)

      assert result.valid == false
      assert Enum.any?(result.errors, &(&1.type == :empty_task_name))
    end

    test "detects duplicate task names" do
      json = """
      {
        "tasks": [
          {"name": "test", "command": "echo test1"},
          {"name": "test", "command": "echo test2"}
        ]
      }
      """

      result = Validate.validate_json(json)

      assert result.valid == false
      assert Enum.any?(result.errors, &(&1.type == :duplicate_task))
    end

    test "detects task depending on itself" do
      json = """
      {
        "tasks": [
          {"name": "test", "command": "echo test", "depends_on": ["test"]}
        ]
      }
      """

      result = Validate.validate_json(json)

      assert result.valid == false
      assert Enum.any?(result.errors, &(&1.type == :self_dependency))
    end
  end

  describe "validate_json/1" do
    test "returns structured result" do
      json = """
      {
        "tasks": [
          {"name": "test", "command": "go test ./..."}
        ]
      }
      """

      result = Validate.validate_json(json)

      assert %Validate.Result{} = result
      assert result.valid == true
      assert result.tasks == ["test"]
      assert result.errors == []
    end

    test "handles invalid JSON" do
      result = Validate.validate_json("not json")

      assert result.valid == false
      assert Enum.any?(result.errors, &(&1.type == :invalid_json))
    end

    test "handles empty tasks list" do
      json = """
      {"tasks": []}
      """

      result = Validate.validate_json(json)

      assert result.valid == true
      assert result.tasks == []
      assert result.warnings == [{:no_tasks, "Pipeline has no tasks"}]
    end
  end

  describe "format_errors/1" do
    test "formats errors for CLI output" do
      result = %Validate.Result{
        valid: false,
        tasks: ["build"],
        errors: [
          %{
            type: :missing_dependency,
            task: "build",
            dependency: "test",
            message: "Task 'build' depends on unknown task 'test'"
          }
        ],
        warnings: []
      }

      output = Validate.format_errors(result)

      assert output =~ "depends on unknown task"
      assert output =~ "build"
    end
  end

  describe "to_json/1" do
    test "returns JSON representation" do
      result = %Validate.Result{
        valid: true,
        tasks: ["test", "build"],
        errors: [],
        warnings: []
      }

      json = Validate.to_json(result)
      decoded = Jason.decode!(json)

      assert decoded["valid"] == true
      assert decoded["tasks"] == ["test", "build"]
      assert decoded["errors"] == []
    end
  end
end
