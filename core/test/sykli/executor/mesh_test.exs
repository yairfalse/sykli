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

  describe "run_job/2" do
    test "dispatches to local when no remote nodes" do
      task = make_task("test", command: "echo hello")

      result = Mesh.run_job(task, workdir: "/tmp")

      assert result == :ok
    end

    test "handles task failure" do
      task = make_task("fail", command: "exit 1")

      result = Mesh.run_job(task, workdir: "/tmp")

      assert {:error, {:exit_code, 1}} = result
    end

    test "handles timeout" do
      task = make_task("slow", command: "sleep 10", timeout: 1)

      result = Mesh.run_job(task, workdir: "/tmp")

      assert {:error, :timeout} = result
    end

    test "uses workdir option" do
      workdir = Path.join(System.tmp_dir!(), "mesh_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(workdir)

      on_exit(fn -> File.rm_rf!(workdir) end)

      task = make_task("workdir-test", command: "pwd")

      result = Mesh.run_job(task, workdir: workdir)

      assert result == :ok
    end
  end

  describe "behaviour implementation" do
    test "available?/0 returns true for non-coordinator nodes" do
      # In test environment, we're a :full node (nonode@nohost)
      assert Mesh.available?() == true
    end

    test "name/0 returns mesh" do
      assert Mesh.name() == "mesh"
    end
  end

  describe "service delegation" do
    test "start_services delegates to Local" do
      # Should not crash - delegates to Local executor
      result = Mesh.start_services("test-task", [])
      assert {:ok, _} = result
    end

    test "stop_services delegates to Local" do
      {:ok, network_info} = Mesh.start_services("test-task", [])
      result = Mesh.stop_services(network_info)
      assert result == :ok
    end
  end

  describe "secret resolution" do
    test "resolve_secret delegates to Local" do
      # Non-existent secret returns error
      result = Mesh.resolve_secret("NON_EXISTENT_SECRET_XYZ")
      assert {:error, :not_found} = result
    end

    test "resolve_secret finds environment variables" do
      # Set a test env var
      System.put_env("SYKLI_TEST_SECRET", "test_value")
      on_exit(fn -> System.delete_env("SYKLI_TEST_SECRET") end)

      result = Mesh.resolve_secret("SYKLI_TEST_SECRET")
      assert {:ok, "test_value"} = result
    end
  end

  describe "artifact handling" do
    test "copy_artifact delegates to Local" do
      workdir =
        Path.join(System.tmp_dir!(), "mesh_artifact_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workdir)
      on_exit(fn -> File.rm_rf!(workdir) end)

      # Create a source file (using relative path from workdir)
      source_file = "source.txt"
      source_abs = Path.join(workdir, source_file)
      File.write!(source_abs, "test content")

      # Copy artifact (using relative paths - the executor resolves them against workdir)
      dest_file = "dest.txt"
      result = Mesh.copy_artifact(source_file, dest_file, workdir)

      assert result == :ok
      assert File.read!(Path.join(workdir, dest_file)) == "test content"
    end

    test "copy_artifact returns error for non-existent source" do
      workdir = System.tmp_dir!()
      result = Mesh.copy_artifact("nonexistent_file.txt", "dest.txt", workdir)

      assert {:error, _reason} = result
    end

    test "artifact_path delegates to Local" do
      workdir = System.tmp_dir!()
      result = Mesh.artifact_path("my_task", "my_artifact", workdir)

      # Should return a path in the .sykli/artifacts directory
      assert is_binary(result)
      assert String.contains?(result, "my_task")
      assert String.contains?(result, "my_artifact")
    end
  end
end
