defmodule Sykli.Target.LocalTest do
  use ExUnit.Case, async: true

  alias Sykli.Target.Local

  # ─────────────────────────────────────────────────────────────────────────────
  # IDENTITY
  # ─────────────────────────────────────────────────────────────────────────────

  describe "name/0" do
    test "returns 'local'" do
      assert Local.name() == "local"
    end
  end

  describe "available?/0" do
    test "returns {:ok, info} when docker is available" do
      # This test assumes docker is installed on dev machines
      case Local.available?() do
        {:ok, info} ->
          assert is_map(info)

        {:error, :no_docker} ->
          # Docker not installed, that's ok for CI
          :ok
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # LIFECYCLE
  # ─────────────────────────────────────────────────────────────────────────────

  describe "setup/1" do
    test "returns {:ok, state} with workdir" do
      assert {:ok, state} = Local.setup(workdir: "/tmp/test")
      assert state.workdir == "/tmp/test"
    end

    test "defaults workdir to current directory" do
      assert {:ok, state} = Local.setup([])
      # Workdir is expanded to absolute path
      assert is_binary(state.workdir)
      assert String.starts_with?(state.workdir, "/")
    end
  end

  describe "teardown/1" do
    test "returns :ok" do
      {:ok, state} = Local.setup([])
      assert :ok = Local.teardown(state)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SECRETS
  # ─────────────────────────────────────────────────────────────────────────────

  describe "resolve_secret/2" do
    test "reads from environment variable" do
      System.put_env("TEST_SECRET_LOCAL", "secret_value")
      {:ok, state} = Local.setup([])

      assert {:ok, "secret_value"} = Local.resolve_secret("TEST_SECRET_LOCAL", state)

      System.delete_env("TEST_SECRET_LOCAL")
    end

    test "returns error for missing secret" do
      {:ok, state} = Local.setup([])
      assert {:error, :not_found} = Local.resolve_secret("NONEXISTENT_SECRET_XYZ", state)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VOLUMES
  # ─────────────────────────────────────────────────────────────────────────────

  describe "create_volume/3" do
    test "returns volume reference" do
      {:ok, state} = Local.setup([])

      assert {:ok, volume} = Local.create_volume("test-vol", %{}, state)
      assert volume.id == "test-vol"
      assert is_binary(volume.reference)
    end
  end

  describe "artifact_path/4" do
    test "returns path in .sykli/artifacts" do
      {:ok, state} = Local.setup(workdir: "/tmp/project")

      path = Local.artifact_path("build", "binary", "/tmp/project", state)

      assert path == "/tmp/project/.sykli/artifacts/build/binary"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SERVICES
  # ─────────────────────────────────────────────────────────────────────────────

  describe "start_services/3" do
    test "returns {:ok, network_info} for empty services" do
      {:ok, state} = Local.setup([])

      # Returns {network, containers, runtime} tuple
      assert {:ok, {nil, [], nil}} = Local.start_services("test", [], state)
    end

    test "uses deterministic service network names for the same task and workdir" do
      service = %Sykli.Graph.Service{name: "db", image: "postgres:15"}
      state = %Local{workdir: "/tmp/sykli-project", runtime: Sykli.Runtime.Fake}

      assert {:ok, {network_a, _containers_a, Sykli.Runtime.Fake}} =
               Local.start_services("integration/test", [service], state)

      assert {:ok, {network_b, _containers_b, Sykli.Runtime.Fake}} =
               Local.start_services("integration/test", [service], state)

      assert network_a == network_b
      assert String.starts_with?(network_a, "sykli-integration_test-")
    end
  end

  describe "stop_services/2" do
    test "returns :ok for nil network" do
      {:ok, state} = Local.setup([])

      # Takes {network, containers, runtime} tuple
      assert :ok = Local.stop_services({nil, [], nil}, state)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # TASK EXECUTION (basic tests, full tests elsewhere)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "run_task/3" do
    test "runs simple shell command" do
      {:ok, state} = Local.setup(workdir: ".")

      task = %Sykli.Graph.Task{
        name: "echo-test",
        command: "echo hello",
        container: nil
      }

      assert {:ok, _output} = Local.run_task(task, state, [])
    end

    test "returns error for failing command" do
      {:ok, state} = Local.setup(workdir: ".")

      task = %Sykli.Graph.Task{
        name: "fail-test",
        command: "exit 1",
        container: nil
      }

      # Returns Error struct with exit_code 1
      assert {:error, %Sykli.Error{code: "task_failed", exit_code: 1}} =
               Local.run_task(task, state, [])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # STATELESS EXECUTION (for RPC / Mesh)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "run_task_stateless/2" do
    test "runs task without requiring external setup/teardown" do
      task = %Sykli.Graph.Task{
        name: "stateless-echo",
        command: "echo stateless",
        container: nil
      }

      assert {:ok, _output} = Local.run_task_stateless(task, workdir: ".")
    end

    test "returns error for failing command" do
      task = %Sykli.Graph.Task{
        name: "stateless-fail",
        command: "exit 42",
        container: nil
      }

      # Returns Error struct with exit_code 42
      assert {:error, %Sykli.Error{code: "task_failed", exit_code: 42}} =
               Local.run_task_stateless(task, workdir: ".")
    end

    test "fails when workdir does not exist" do
      task = %Sykli.Graph.Task{
        name: "bad-workdir",
        command: "echo hello",
        container: nil
      }

      # Shell commands fail when workdir doesn't exist (can't cd)
      result = Local.run_task_stateless(task, workdir: "/nonexistent/path/xyz")
      assert {:error, %Sykli.Error{code: "task_failed"}} = result
    end
  end

  describe "copy_artifact/4" do
    @tag :tmp_dir
    test "rejects symlink sources instead of following them", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "real.txt")
      link = Path.join(tmp_dir, "link.txt")

      File.write!(source, "artifact")
      File.ln_s!("real.txt", link)

      {:ok, state} = Local.setup(workdir: tmp_dir)

      assert {:error, {:symlink_not_allowed, "link.txt"}} =
               Local.copy_artifact("link.txt", "dest.txt", tmp_dir, state)

      refute File.exists?(Path.join(tmp_dir, "dest.txt"))
    end
  end
end
