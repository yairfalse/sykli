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
end
