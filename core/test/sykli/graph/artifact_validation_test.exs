defmodule Sykli.Graph.ArtifactValidationTest do
  @moduledoc """
  TDD tests for artifact graph validation.

  These tests verify that the artifact dependency graph is valid BEFORE execution:
  1. All task_inputs reference existing tasks
  2. All task_inputs reference declared outputs
  3. Circular artifact dependencies are detected
  4. Artifact dependencies imply task dependencies (fail if missing)
  """

  use ExUnit.Case, async: true

  alias Sykli.Graph
  alias Sykli.Graph.Task
  alias Sykli.Graph.TaskInput

  # ─────────────────────────────────────────────────────────────────────────────
  # VALID ARTIFACT GRAPHS
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate_artifacts/1 with valid graphs" do
    test "passes for tasks with no artifacts" do
      graph = %{
        "build" => %Task{
          name: "build",
          command: "go build",
          outputs: %{},
          depends_on: [],
          task_inputs: []
        },
        "test" => %Task{
          name: "test",
          command: "go test",
          outputs: %{},
          depends_on: ["build"],
          task_inputs: []
        }
      }

      assert :ok = Graph.validate_artifacts(graph)
    end

    test "passes for valid artifact dependency" do
      graph = %{
        "build" => %Task{
          name: "build",
          command: "go build -o app",
          outputs: %{"binary" => "app"},
          depends_on: [],
          task_inputs: []
        },
        "package" => %Task{
          name: "package",
          command: "tar -czf app.tar.gz app",
          outputs: %{},
          depends_on: ["build"],
          task_inputs: [
            %TaskInput{from_task: "build", output: "binary", dest: "app"}
          ]
        }
      }

      assert :ok = Graph.validate_artifacts(graph)
    end

    test "passes for multi-hop artifact chain" do
      graph = %{
        "compile" => %Task{
          name: "compile",
          command: "gcc -c main.c",
          outputs: %{"object" => "main.o"},
          depends_on: [],
          task_inputs: []
        },
        "link" => %Task{
          name: "link",
          command: "gcc -o app main.o",
          outputs: %{"binary" => "app"},
          depends_on: ["compile"],
          task_inputs: [
            %TaskInput{from_task: "compile", output: "object", dest: "main.o"}
          ]
        },
        "package" => %Task{
          name: "package",
          command: "tar -czf app.tar.gz app",
          outputs: %{"archive" => "app.tar.gz"},
          depends_on: ["link"],
          task_inputs: [
            %TaskInput{from_task: "link", output: "binary", dest: "app"}
          ]
        }
      }

      assert :ok = Graph.validate_artifacts(graph)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # MISSING SOURCE TASK
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate_artifacts/1 with missing source task" do
    test "fails when task_input references non-existent task" do
      graph = %{
        "package" => %Task{
          name: "package",
          command: "tar -czf app.tar.gz app",
          outputs: %{},
          depends_on: [],
          task_inputs: [
            %TaskInput{from_task: "build", output: "binary", dest: "app"}
          ]
        }
      }

      assert {:error, {:source_task_not_found, "package", "build"}} =
               Graph.validate_artifacts(graph)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # MISSING OUTPUT
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate_artifacts/1 with missing output" do
    test "fails when task_input references undeclared output" do
      graph = %{
        "build" => %Task{
          name: "build",
          command: "go build",
          # No outputs declared!
          outputs: %{},
          depends_on: [],
          task_inputs: []
        },
        "package" => %Task{
          name: "package",
          command: "tar -czf app.tar.gz app",
          outputs: %{},
          depends_on: ["build"],
          task_inputs: [
            %TaskInput{from_task: "build", output: "binary", dest: "app"}
          ]
        }
      }

      assert {:error, {:output_not_found, "package", "build", "binary"}} =
               Graph.validate_artifacts(graph)
    end

    test "fails when task_input references wrong output name" do
      graph = %{
        "build" => %Task{
          name: "build",
          command: "go build -o app",
          # Named "app", not "binary"
          outputs: %{"app" => "app"},
          depends_on: [],
          task_inputs: []
        },
        "package" => %Task{
          name: "package",
          command: "tar -czf app.tar.gz app",
          outputs: %{},
          depends_on: ["build"],
          task_inputs: [
            # Wrong name!
            %TaskInput{from_task: "build", output: "binary", dest: "app"}
          ]
        }
      }

      assert {:error, {:output_not_found, "package", "build", "binary"}} =
               Graph.validate_artifacts(graph)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # MISSING TASK DEPENDENCY
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate_artifacts/1 with missing task dependency" do
    test "fails when artifact dependency doesn't imply task dependency" do
      # This catches a subtle bug: you can't receive an artifact from a task
      # that might not have run yet (race condition)
      graph = %{
        "build" => %Task{
          name: "build",
          command: "go build -o app",
          outputs: %{"binary" => "app"},
          depends_on: [],
          task_inputs: []
        },
        "package" => %Task{
          name: "package",
          command: "tar -czf app.tar.gz app",
          outputs: %{},
          # Missing dependency on "build"!
          depends_on: [],
          task_inputs: [
            %TaskInput{from_task: "build", output: "binary", dest: "app"}
          ]
        }
      }

      assert {:error, {:missing_task_dependency, "package", "build"}} =
               Graph.validate_artifacts(graph)
    end

    test "passes when dependency is transitive" do
      # package depends on link, link depends on build
      # So package can receive artifacts from build (transitive)
      graph = %{
        "build" => %Task{
          name: "build",
          command: "go build -o app",
          outputs: %{"binary" => "app"},
          depends_on: [],
          task_inputs: []
        },
        "link" => %Task{
          name: "link",
          command: "strip app",
          outputs: %{"stripped" => "app"},
          depends_on: ["build"],
          task_inputs: [
            %TaskInput{from_task: "build", output: "binary", dest: "app"}
          ]
        },
        "package" => %Task{
          name: "package",
          command: "tar -czf app.tar.gz app",
          outputs: %{},
          # Only depends on link, not build directly
          depends_on: ["link"],
          task_inputs: [
            # But receives artifact from build (via link)
            %TaskInput{from_task: "build", output: "binary", dest: "original_app"}
          ]
        }
      }

      # This should PASS because build transitively precedes package
      assert :ok = Graph.validate_artifacts(graph)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # MULTIPLE ERRORS
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate_artifacts/1 returns first error" do
    test "returns first error found" do
      graph = %{
        "package" => %Task{
          name: "package",
          command: "tar",
          outputs: %{},
          depends_on: [],
          task_inputs: [
            %TaskInput{from_task: "nonexistent", output: "foo", dest: "foo"},
            %TaskInput{from_task: "also_nonexistent", output: "bar", dest: "bar"}
          ]
        }
      }

      # Should fail on first missing task
      assert {:error, {:source_task_not_found, "package", "nonexistent"}} =
               Graph.validate_artifacts(graph)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPER: has_artifact_dependencies?/1
  # ─────────────────────────────────────────────────────────────────────────────

  describe "has_artifact_dependencies?/1" do
    test "returns false for graph with no task_inputs" do
      graph = %{
        "build" => %Task{name: "build", command: "go build", task_inputs: []},
        "test" => %Task{name: "test", command: "go test", task_inputs: nil}
      }

      assert Graph.has_artifact_dependencies?(graph) == false
    end

    test "returns true for graph with task_inputs" do
      graph = %{
        "build" => %Task{
          name: "build",
          command: "go build",
          outputs: %{"binary" => "app"},
          task_inputs: []
        },
        "package" => %Task{
          name: "package",
          command: "tar",
          task_inputs: [
            %TaskInput{from_task: "build", output: "binary", dest: "app"}
          ]
        }
      }

      assert Graph.has_artifact_dependencies?(graph) == true
    end
  end
end
