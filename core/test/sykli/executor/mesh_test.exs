defmodule Sykli.Executor.MeshTest do
  use ExUnit.Case, async: false

  alias Sykli.Executor.Mesh
  alias Sykli.Graph.Task

  # Helper to create a task struct
  defp make_task(name, opts \\ []) do
    %Task{
      name: name,
      command: Keyword.get(opts, :command, "echo #{name}"),
      inputs: Keyword.get(opts, :inputs, []),
      outputs: Keyword.get(opts, :outputs, []),
      depends_on: Keyword.get(opts, :depends_on, []),
      container: Keyword.get(opts, :container),
      workdir: Keyword.get(opts, :workdir),
      env: Keyword.get(opts, :env, %{}),
      mounts: Keyword.get(opts, :mounts, []),
      timeout: Keyword.get(opts, :timeout, 300)
    }
  end

  # Helper to setup Mesh target
  defp setup_mesh(opts \\ []) do
    workdir = Keyword.get(opts, :workdir, "/tmp")
    {:ok, state} = Mesh.setup(workdir: workdir)
    state
  end

  describe "run_task/3" do
    test "dispatches to local when no remote nodes" do
      state = setup_mesh()
      task = make_task("test", command: "echo hello")

      result = Mesh.run_task(task, state, [])

      assert result == :ok
      Mesh.teardown(state)
    end

    test "handles task failure" do
      state = setup_mesh()
      task = make_task("fail", command: "exit 1")

      result = Mesh.run_task(task, state, [])

      # Mesh wraps failures in PlacementError with details of which nodes were tried
      assert {:error, %Sykli.NodeSelector.PlacementError{} = error} = result
      assert error.task_name == "fail"
      # Failures contain Error structs
      assert Enum.any?(error.failures, fn
               {:local, %Sykli.Error{code: "task_failed"}} -> true
               _ -> false
             end)

      Mesh.teardown(state)
    end

    test "handles timeout" do
      state = setup_mesh()
      task = make_task("slow", command: "sleep 10", timeout: 1)

      result = Mesh.run_task(task, state, [])

      # Mesh wraps failures in PlacementError with details of which nodes were tried
      assert {:error, %Sykli.NodeSelector.PlacementError{} = error} = result
      assert error.task_name == "slow"
      # Failures contain Error structs with code "task_timeout"
      assert Enum.any?(error.failures, fn
               {:local, %Sykli.Error{code: "task_timeout"}} -> true
               _ -> false
             end)

      Mesh.teardown(state)
    end

    test "uses workdir option" do
      workdir = Path.join(System.tmp_dir!(), "mesh_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(workdir)

      on_exit(fn -> File.rm_rf!(workdir) end)

      state = setup_mesh(workdir: workdir)
      task = make_task("workdir-test", command: "pwd")

      result = Mesh.run_task(task, state, [])

      assert result == :ok
      Mesh.teardown(state)
    end
  end

  describe "behaviour implementation" do
    test "available?/0 returns {:ok, info} for non-coordinator nodes" do
      # In test environment, we're a :full node (nonode@nohost)
      assert {:ok, %{nodes: _}} = Mesh.available?()
    end

    test "name/0 returns mesh" do
      assert Mesh.name() == "mesh"
    end
  end

  describe "service delegation" do
    test "start_services delegates to Local" do
      state = setup_mesh()
      # Should not crash - delegates to Local target
      result = Mesh.start_services("test-task", [], state)
      assert {:ok, _} = result
      Mesh.teardown(state)
    end

    test "stop_services delegates to Local" do
      state = setup_mesh()
      {:ok, network_info} = Mesh.start_services("test-task", [], state)
      result = Mesh.stop_services(network_info, state)
      assert result == :ok
      Mesh.teardown(state)
    end
  end

  describe "secret resolution" do
    test "resolve_secret delegates to Local" do
      state = setup_mesh()
      # Non-existent secret returns error
      result = Mesh.resolve_secret("NON_EXISTENT_SECRET_XYZ", state)
      assert {:error, :not_found} = result
      Mesh.teardown(state)
    end

    test "resolve_secret finds environment variables" do
      # Set a test env var
      System.put_env("SYKLI_TEST_SECRET", "test_value")
      on_exit(fn -> System.delete_env("SYKLI_TEST_SECRET") end)

      state = setup_mesh()
      result = Mesh.resolve_secret("SYKLI_TEST_SECRET", state)
      assert {:ok, "test_value"} = result
      Mesh.teardown(state)
    end
  end

  describe "artifact handling" do
    test "copy_artifact delegates to Local" do
      workdir =
        Path.join(System.tmp_dir!(), "mesh_artifact_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workdir)
      on_exit(fn -> File.rm_rf!(workdir) end)

      state = setup_mesh(workdir: workdir)

      # Create a source file (using relative path from workdir)
      source_file = "source.txt"
      source_abs = Path.join(workdir, source_file)
      File.write!(source_abs, "test content")

      # Copy artifact (using relative paths - the target resolves them against workdir)
      dest_file = "dest.txt"
      result = Mesh.copy_artifact(source_file, dest_file, workdir, state)

      assert result == :ok
      assert File.read!(Path.join(workdir, dest_file)) == "test content"
      Mesh.teardown(state)
    end

    test "copy_artifact returns error for non-existent source" do
      workdir = System.tmp_dir!()
      state = setup_mesh(workdir: workdir)
      result = Mesh.copy_artifact("nonexistent_file.txt", "dest.txt", workdir, state)

      assert {:error, _reason} = result
      Mesh.teardown(state)
    end

    test "artifact_path delegates to Local" do
      workdir = System.tmp_dir!()
      state = setup_mesh(workdir: workdir)
      result = Mesh.artifact_path("my_task", "my_artifact", workdir, state)

      # Should return a path in the .sykli/artifacts directory
      assert is_binary(result)
      assert String.contains?(result, "my_task")
      assert String.contains?(result, "my_artifact")
      Mesh.teardown(state)
    end
  end
end
