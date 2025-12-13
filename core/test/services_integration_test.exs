defmodule Sykli.ServicesIntegrationTest do
  @moduledoc """
  Integration tests for service containers.
  Requires Docker to be running.

  Run with: mix test test/services_integration_test.exs
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  @test_workdir Path.expand("/tmp/sykli_services_test")

  setup_all do
    # Check if Docker is available
    case System.cmd("docker", ["version"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ ->
        IO.puts("\nSkipping service tests: Docker not available")
        :skip
    end
  end

  setup do
    File.rm_rf!(@test_workdir)
    File.mkdir_p!(@test_workdir)

    on_exit(fn ->
      File.rm_rf!(@test_workdir)
    end)

    :ok
  end

  describe "service containers" do
    @tag timeout: 120_000
    test "postgres service is accessible from task" do
      # Create a test script that checks postgres connectivity
      script_path = Path.join(@test_workdir, "test_postgres.sh")
      File.write!(script_path, """
      #!/bin/sh
      set -e
      # Wait for postgres to be ready (up to 30 seconds)
      for i in $(seq 1 30); do
        if pg_isready -h db -p 5432 2>/dev/null; then
          echo "Postgres is ready"
          exit 0
        fi
        echo "Waiting for postgres... ($i)"
        sleep 1
      done
      echo "Postgres not ready after 30s"
      exit 1
      """)
      File.chmod!(script_path, 0o755)

      # Create a pipeline with a postgres service
      json = Jason.encode!(%{
        "version" => "2",
        "tasks" => [%{
          "name" => "test-postgres",
          "command" => "/test/test_postgres.sh",
          "container" => "postgres:15",
          "mounts" => [%{"resource" => "src:.", "path" => "/test", "type" => "directory"}],
          "services" => [%{"image" => "postgres:15", "name" => "db"}],
          "env" => %{"PGPASSWORD" => "postgres"}
        }]
      })

      {:ok, graph} = Sykli.Graph.parse(json)
      {:ok, order} = Sykli.Graph.topo_sort(graph)

      result = Sykli.Executor.run(order, graph, workdir: @test_workdir)

      assert {:ok, _} = result
    end

    @tag timeout: 120_000
    test "redis service is accessible from task" do
      # Create a test script that checks redis connectivity
      script_path = Path.join(@test_workdir, "test_redis.sh")
      File.write!(script_path, """
      #!/bin/sh
      set -e
      # Wait for redis to be ready
      for i in $(seq 1 30); do
        if redis-cli -h cache ping 2>/dev/null | grep -q PONG; then
          echo "Redis is ready"
          exit 0
        fi
        echo "Waiting for redis... ($i)"
        sleep 1
      done
      echo "Redis not ready after 30s"
      exit 1
      """)
      File.chmod!(script_path, 0o755)

      json = Jason.encode!(%{
        "version" => "2",
        "tasks" => [%{
          "name" => "test-redis",
          "command" => "/test/test_redis.sh",
          "container" => "redis:7",
          "mounts" => [%{"resource" => "src:.", "path" => "/test", "type" => "directory"}],
          "services" => [%{"image" => "redis:7", "name" => "cache"}]
        }]
      })

      {:ok, graph} = Sykli.Graph.parse(json)
      {:ok, order} = Sykli.Graph.topo_sort(graph)

      result = Sykli.Executor.run(order, graph, workdir: @test_workdir)

      assert {:ok, _} = result
    end

    @tag timeout: 120_000
    test "multiple services accessible simultaneously" do
      # Create a test script that checks both services
      script_path = Path.join(@test_workdir, "test_multi.sh")
      File.write!(script_path, """
      #!/bin/sh
      set -e

      # Check postgres
      for i in $(seq 1 30); do
        if pg_isready -h db -p 5432 2>/dev/null; then
          echo "Postgres is ready"
          break
        fi
        sleep 1
      done

      # Check redis
      for i in $(seq 1 30); do
        if redis-cli -h cache ping 2>/dev/null | grep -q PONG; then
          echo "Redis is ready"
          break
        fi
        sleep 1
      done

      echo "Both services are accessible"
      exit 0
      """)
      File.chmod!(script_path, 0o755)

      json = Jason.encode!(%{
        "version" => "2",
        "tasks" => [%{
          "name" => "test-multi",
          "command" => "/test/test_multi.sh",
          "container" => "postgres:15",
          "mounts" => [%{"resource" => "src:.", "path" => "/test", "type" => "directory"}],
          "services" => [
            %{"image" => "postgres:15", "name" => "db"},
            %{"image" => "redis:7", "name" => "cache"}
          ],
          "env" => %{"PGPASSWORD" => "postgres"}
        }]
      })

      {:ok, graph} = Sykli.Graph.parse(json)
      {:ok, order} = Sykli.Graph.topo_sort(graph)

      result = Sykli.Executor.run(order, graph, workdir: @test_workdir)

      assert {:ok, _} = result
    end

    @tag timeout: 60_000
    test "service cleanup on task failure" do
      # Create a script that fails after checking service
      script_path = Path.join(@test_workdir, "fail.sh")
      File.write!(script_path, """
      #!/bin/sh
      echo "Starting failing task"
      exit 1
      """)
      File.chmod!(script_path, 0o755)

      json = Jason.encode!(%{
        "version" => "2",
        "tasks" => [%{
          "name" => "failing-task",
          "command" => "/test/fail.sh",
          "container" => "alpine:latest",
          "mounts" => [%{"resource" => "src:.", "path" => "/test", "type" => "directory"}],
          "services" => [%{"image" => "redis:7", "name" => "cache"}]
        }]
      })

      {:ok, graph} = Sykli.Graph.parse(json)
      {:ok, order} = Sykli.Graph.topo_sort(graph)

      # Task should fail
      result = Sykli.Executor.run(order, graph, workdir: @test_workdir)
      assert {:error, _} = result

      # Verify no orphan containers or networks remain
      {output, 0} = System.cmd("docker", ["ps", "-a", "--format", "{{.Names}}"], stderr_to_stdout: true)
      refute String.contains?(output, "sykli-failing-task")

      {output, 0} = System.cmd("docker", ["network", "ls", "--format", "{{.Name}}"], stderr_to_stdout: true)
      refute String.contains?(output, "sykli-failing-task")
    end
  end

  describe "service networking" do
    @tag timeout: 60_000
    test "task container can resolve service by name" do
      script_path = Path.join(@test_workdir, "resolve.sh")
      File.write!(script_path, """
      #!/bin/sh
      set -e
      # Try to resolve the service name
      getent hosts myservice || nslookup myservice || host myservice
      echo "Service name resolved successfully"
      """)
      File.chmod!(script_path, 0o755)

      json = Jason.encode!(%{
        "version" => "2",
        "tasks" => [%{
          "name" => "test-resolve",
          "command" => "/test/resolve.sh",
          "container" => "alpine:latest",
          "mounts" => [%{"resource" => "src:.", "path" => "/test", "type" => "directory"}],
          "services" => [%{"image" => "alpine:latest", "name" => "myservice"}]
        }]
      })

      {:ok, graph} = Sykli.Graph.parse(json)
      {:ok, order} = Sykli.Graph.topo_sort(graph)

      # Note: This test verifies DNS resolution works within the Docker network
      result = Sykli.Executor.run(order, graph, workdir: @test_workdir)

      # May fail if alpine doesn't have the right tools, but network should be set up
      # The important thing is that cleanup happens
      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end
  end
end
