defmodule Sykli.Executor.OptsThreadingTest do
  @moduledoc """
  Tests for issue #54: Executor opts threading through to targets.

  Verifies that options passed to Sykli.run/2 and Executor.run/3 are
  properly propagated to target implementations.
  """

  use ExUnit.Case, async: true

  alias Sykli.Executor

  # Mock target that captures opts for verification
  defmodule MockTarget do
    @behaviour Sykli.Target.Behaviour

    # Use process dictionary to capture opts (works in tests)
    def get_captured_opts do
      Process.get(:mock_target_opts, [])
    end

    @impl true
    def name, do: "mock"

    @impl true
    def available?, do: {:ok, %{mode: :test}}

    @impl true
    def setup(opts) do
      # Capture the opts passed to setup
      Process.put(:mock_target_opts, opts)
      {:ok, %{workdir: Keyword.get(opts, :workdir, "."), captured_opts: opts}}
    end

    @impl true
    def teardown(_state), do: :ok

    @impl true
    def resolve_secret(_name, _state), do: {:error, :not_found}

    @impl true
    def create_volume(_name, _opts, _state), do: {:ok, %{id: "mock", host_path: nil, reference: "mock"}}

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

  describe "opts threading to target.setup/1" do
    test "passes workdir to target setup" do
      graph = %{
        "test-task" => %Sykli.Graph.Task{
          name: "test-task",
          command: "echo test",
          depends_on: []
        }
      }

      tasks = [graph["test-task"]]

      # Run with specific workdir
      _result = Executor.run(tasks, graph, target: MockTarget, workdir: "/custom/path")

      captured = MockTarget.get_captured_opts()
      assert Keyword.get(captured, :workdir) == "/custom/path"
    end

    test "passes git_context to target setup" do
      graph = %{
        "test-task" => %Sykli.Graph.Task{
          name: "test-task",
          command: "echo test",
          depends_on: []
        }
      }

      tasks = [graph["test-task"]]

      git_ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: "abc123def456",
        dirty: false
      }

      _result =
        Executor.run(tasks, graph,
          target: MockTarget,
          workdir: ".",
          git_context: git_ctx
        )

      captured = MockTarget.get_captured_opts()
      assert Keyword.get(captured, :git_context) == git_ctx
    end

    test "passes git_ssh_secret to target setup" do
      graph = %{
        "test-task" => %Sykli.Graph.Task{
          name: "test-task",
          command: "echo test",
          depends_on: []
        }
      }

      tasks = [graph["test-task"]]

      _result =
        Executor.run(tasks, graph,
          target: MockTarget,
          workdir: ".",
          git_ssh_secret: "my-ssh-key"
        )

      captured = MockTarget.get_captured_opts()
      assert Keyword.get(captured, :git_ssh_secret) == "my-ssh-key"
    end

    test "passes git_token_secret to target setup" do
      graph = %{
        "test-task" => %Sykli.Graph.Task{
          name: "test-task",
          command: "echo test",
          depends_on: []
        }
      }

      tasks = [graph["test-task"]]

      _result =
        Executor.run(tasks, graph,
          target: MockTarget,
          workdir: ".",
          git_token_secret: "my-token"
        )

      captured = MockTarget.get_captured_opts()
      assert Keyword.get(captured, :git_token_secret) == "my-token"
    end

    test "passes all opts together" do
      graph = %{
        "test-task" => %Sykli.Graph.Task{
          name: "test-task",
          command: "echo test",
          depends_on: []
        }
      }

      tasks = [graph["test-task"]]

      git_ctx = %{
        url: "git@github.com:org/repo.git",
        branch: "feature",
        sha: "deadbeef123456",
        dirty: false
      }

      _result =
        Executor.run(tasks, graph,
          target: MockTarget,
          workdir: "/project",
          git_context: git_ctx,
          git_ssh_secret: "deploy-key",
          namespace: "sykli-jobs",
          custom_option: "custom_value"
        )

      captured = MockTarget.get_captured_opts()

      # All opts should be present
      assert Keyword.get(captured, :workdir) == "/project"
      assert Keyword.get(captured, :git_context) == git_ctx
      assert Keyword.get(captured, :git_ssh_secret) == "deploy-key"
      assert Keyword.get(captured, :namespace) == "sykli-jobs"
      assert Keyword.get(captured, :custom_option) == "custom_value"
    end
  end
end
