defmodule Sykli.Executor.ArtifactValidationTest do
  @moduledoc """
  Tests for artifact graph validation in the executor.

  The executor should validate the artifact graph BEFORE running any tasks,
  failing fast with a clear error if the graph is invalid.
  """

  use ExUnit.Case, async: true

  alias Sykli.Error
  alias Sykli.Executor
  alias Sykli.Graph.Task
  alias Sykli.Graph.TaskInput

  # Mock target that captures opts for verification
  defmodule MockTarget do
    @behaviour Sykli.Target.Behaviour

    @impl true
    def name, do: "mock"

    @impl true
    def available?, do: {:ok, %{mode: :test}}

    @impl true
    def setup(opts) do
      {:ok, %{workdir: Keyword.get(opts, :workdir, ".")}}
    end

    @impl true
    def teardown(_state), do: :ok

    @impl true
    def resolve_secret(_name, _state), do: {:error, :not_found}

    @impl true
    def create_volume(_name, _opts, _state),
      do: {:ok, %{id: "mock", host_path: nil, reference: "mock"}}

    @impl true
    def artifact_path(_task, _artifact, _workdir, _state), do: "/mock/path"

    @impl true
    def copy_artifact(_src, _dest, _workdir, _state), do: :ok

    @impl true
    def start_services(_name, _services, _state), do: {:ok, nil}

    @impl true
    def stop_services(_info, _state), do: :ok

    @impl true
    def run_task(_task, _state, _opts), do: :ok
  end

  describe "executor artifact validation" do
    test "fails fast when task_input references non-existent task" do
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

      tasks = [graph["package"]]

      result = Executor.run(tasks, graph, target: MockTarget, workdir: ".")

      # Returns Error struct with code E013 (artifact validation)
      assert {:error, %Error{code: "missing_artifact", type: :validation}} = result
    end

    test "fails fast when task_input references undeclared output" do
      graph = %{
        "build" => %Task{
          name: "build",
          command: "go build",
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

      tasks = [graph["build"], graph["package"]]

      result = Executor.run(tasks, graph, target: MockTarget, workdir: ".")

      # Returns Error struct with code E013 (artifact validation)
      assert {:error, %Error{code: "missing_artifact", type: :validation}} = result
    end

    test "fails fast when artifact dependency doesn't imply task dependency" do
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
          depends_on: [],
          task_inputs: [
            %TaskInput{from_task: "build", output: "binary", dest: "app"}
          ]
        }
      }

      tasks = [graph["build"], graph["package"]]

      result = Executor.run(tasks, graph, target: MockTarget, workdir: ".")

      # Returns Error struct with code E013 (artifact validation)
      assert {:error, %Error{code: "missing_artifact", type: :validation}} = result
    end

    test "runs successfully with valid artifact graph" do
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

      tasks = [graph["build"], graph["package"]]

      result = Executor.run(tasks, graph, target: MockTarget, workdir: ".")

      assert {:ok, _results} = result
    end

    test "runs successfully with no artifacts" do
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

      tasks = [graph["build"], graph["test"]]

      result = Executor.run(tasks, graph, target: MockTarget, workdir: ".")

      assert {:ok, _results} = result
    end
  end
end
