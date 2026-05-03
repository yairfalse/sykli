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

    test "accepts an explicit sykli file path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "sykli.exs")

      File.write!(
        path,
        "IO.puts(~s({\"version\":\"1\",\"tasks\":[{\"name\":\"test\",\"command\":\"echo test\"}]}))"
      )

      assert {:ok, result} = Validate.validate(path)
      assert result.valid
      assert result.tasks == ["test"]
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

    test "detects whitespace-only task name" do
      json = """
      {
        "tasks": [
          {"name": "   ", "command": "echo test"}
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

  describe "validate_json/1 -- missing command" do
    test "detects task with no command" do
      json = ~s({"tasks": [{"name": "test"}]})

      result = Validate.validate_json(json)

      assert result.valid == false
      assert Enum.any?(result.errors, &(&1.type == :missing_command))

      error = Enum.find(result.errors, &(&1.type == :missing_command))
      assert error.task == "test"
    end

    test "detects task with empty command" do
      json = ~s({"tasks": [{"name": "test", "command": ""}]})

      result = Validate.validate_json(json)

      assert result.valid == false
      assert Enum.any?(result.errors, &(&1.type == :missing_command))
    end

    test "exempts gate tasks from command requirement" do
      json =
        ~s({"tasks": [{"name": "approval", "gate": {"strategy": "prompt", "message": "ok?"}}]})

      result = Validate.validate_json(json)

      refute Enum.any?(result.errors, &(&1.type == :missing_command))
    end

    test "exempts review nodes from command requirement" do
      json =
        ~s({"tasks": [{"name": "review:api-breakage", "kind": "review", "primitive": "api-breakage", "agent": "local"}]})

      result = Validate.validate_json(json)

      assert result.valid == true
      refute Enum.any?(result.errors, &(&1.type == :missing_command))
    end

    test "passes when command is present" do
      json = ~s({"tasks": [{"name": "test", "command": "echo hello"}]})

      result = Validate.validate_json(json)

      assert result.valid == true
      refute Enum.any?(result.errors, &(&1.type == :missing_command))
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

  describe "to_map/1" do
    test "returns map representation" do
      result = %Validate.Result{
        valid: true,
        tasks: ["test", "build"],
        errors: [],
        warnings: []
      }

      map = Validate.to_map(result)

      assert map.valid == true
      assert map.tasks == ["test", "build"]
      assert map.errors == []
    end
  end
end
