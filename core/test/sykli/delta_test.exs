defmodule Sykli.DeltaTest do
  use ExUnit.Case, async: false

  alias Sykli.Delta

  @test_workdir Path.expand("/tmp/sykli_delta_test")

  # Helper to create task struct
  defp make_task(name, opts \\ []) do
    %Sykli.Graph.Task{
      name: name,
      command: Keyword.get(opts, :command, "echo #{name}"),
      inputs: Keyword.get(opts, :inputs, []),
      outputs: Keyword.get(opts, :outputs, []),
      depends_on: Keyword.get(opts, :depends_on, []),
      container: Keyword.get(opts, :container),
      workdir: Keyword.get(opts, :workdir),
      env: Keyword.get(opts, :env, %{}),
      mounts: Keyword.get(opts, :mounts, [])
    }
  end

  setup do
    # Clean up and create test directory
    File.rm_rf!(@test_workdir)
    File.mkdir_p!(@test_workdir)

    # Initialize git repo
    System.cmd("git", ["init"], cd: @test_workdir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: @test_workdir)
    System.cmd("git", ["config", "user.name", "Test"], cd: @test_workdir)

    on_exit(fn ->
      File.rm_rf!(@test_workdir)
    end)

    :ok
  end

  describe "affected_tasks/2" do
    test "returns empty list when no changes" do
      # Create and commit a file
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      tasks = [make_task("test", inputs: ["**/*.go"])]

      assert {:ok, []} = Delta.affected_tasks(tasks, path: @test_workdir)
    end

    test "detects directly affected task by glob pattern" do
      # Create and commit a file
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      # Modify the file
      File.write!(Path.join(@test_workdir, "main.go"), "package main\n// modified")

      tasks = [make_task("test", inputs: ["**/*.go"])]

      assert {:ok, ["test"]} = Delta.affected_tasks(tasks, path: @test_workdir)
    end

    test "detects untracked files" do
      # Create and commit initial file
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      # Add new untracked file
      File.write!(Path.join(@test_workdir, "new.go"), "package main")

      tasks = [make_task("test", inputs: ["**/*.go"])]

      assert {:ok, ["test"]} = Delta.affected_tasks(tasks, path: @test_workdir)
    end

    test "includes transitive dependents" do
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      # Modify file
      File.write!(Path.join(@test_workdir, "main.go"), "package main\n// modified")

      tasks = [
        make_task("test", inputs: ["**/*.go"]),
        make_task("build", depends_on: ["test"]),
        make_task("deploy", depends_on: ["build"])
      ]

      {:ok, affected} = Delta.affected_tasks(tasks, path: @test_workdir)

      assert "test" in affected
      assert "build" in affected
      assert "deploy" in affected
    end

    test "does not include unrelated tasks" do
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      File.write!(Path.join(@test_workdir, "docs.md"), "# Docs")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      # Only modify go file
      File.write!(Path.join(@test_workdir, "main.go"), "package main\n// modified")

      tasks = [
        make_task("test", inputs: ["**/*.go"]),
        make_task("docs", inputs: ["**/*.md"])
      ]

      {:ok, affected} = Delta.affected_tasks(tasks, path: @test_workdir)

      assert "test" in affected
      refute "docs" in affected
    end

    test "task with no inputs is not affected" do
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      File.write!(Path.join(@test_workdir, "main.go"), "package main\n// modified")

      # no inputs
      tasks = [make_task("notify")]

      assert {:ok, []} = Delta.affected_tasks(tasks, path: @test_workdir)
    end
  end

  describe "affected_tasks_detailed/2" do
    test "returns detailed info for directly affected tasks" do
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      File.write!(Path.join(@test_workdir, "main.go"), "package main\n// modified")

      tasks = [make_task("test", inputs: ["**/*.go"])]

      {:ok, [detail]} = Delta.affected_tasks_detailed(tasks, path: @test_workdir)

      assert detail.name == "test"
      assert detail.reason == :direct
      assert "main.go" in detail.files
      assert detail.depends_on == nil
    end

    test "returns detailed info for dependent tasks" do
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      File.write!(Path.join(@test_workdir, "main.go"), "package main\n// modified")

      tasks = [
        make_task("test", inputs: ["**/*.go"]),
        make_task("build", depends_on: ["test"])
      ]

      {:ok, details} = Delta.affected_tasks_detailed(tasks, path: @test_workdir)

      test_detail = Enum.find(details, &(&1.name == "test"))
      build_detail = Enum.find(details, &(&1.name == "build"))

      assert test_detail.reason == :direct
      assert build_detail.reason == :dependent
      assert build_detail.depends_on == "test"
      assert build_detail.files == []
    end
  end

  describe "get_changed_files/2" do
    test "returns changed files" do
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      File.write!(Path.join(@test_workdir, "main.go"), "package main\n// modified")
      File.write!(Path.join(@test_workdir, "new.go"), "package main")

      {:ok, files} = Delta.get_changed_files("HEAD", @test_workdir)

      assert "main.go" in files
      assert "new.go" in files
    end
  end

  describe "error handling" do
    test "returns error for non-git directory" do
      # Use /tmp directly - definitely not a git repo
      non_git_dir = "/tmp/sykli_not_a_git_repo_#{System.unique_integer([:positive])}"
      File.mkdir_p!(non_git_dir)

      on_exit(fn -> File.rm_rf!(non_git_dir) end)

      tasks = [make_task("test", inputs: ["**/*.go"])]

      assert {:error, {:not_a_git_repo, ^non_git_dir}} =
               Delta.affected_tasks(tasks, path: non_git_dir)
    end

    test "returns error for unknown ref" do
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      tasks = [make_task("test", inputs: ["**/*.go"])]

      assert {:error, {:unknown_ref, "nonexistent-branch"}} =
               Delta.affected_tasks(tasks, from: "nonexistent-branch", path: @test_workdir)
    end
  end

  describe "format_error/1" do
    test "formats not_a_git_repo error" do
      msg = Delta.format_error({:not_a_git_repo, "/some/path"})
      assert msg == "Not a git repository: /some/path"
    end

    test "formats unknown_ref error" do
      msg = Delta.format_error({:unknown_ref, "main"})
      assert msg =~ "Unknown git reference: main"
      assert msg =~ "Hint:"
    end

    test "formats bad_revision error" do
      msg = Delta.format_error({:bad_revision, "abc123"})
      assert msg =~ "Bad revision: abc123"
      assert msg =~ "Hint:"
    end

    test "formats git_failed error" do
      msg = Delta.format_error({:git_failed, "some error", 1})
      assert msg =~ "Git command failed"
      assert msg =~ "some error"
    end
  end

  describe "glob matching" do
    test "matches ** pattern" do
      File.mkdir_p!(Path.join(@test_workdir, "src/pkg"))
      File.write!(Path.join(@test_workdir, "src/pkg/main.go"), "package pkg")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      File.write!(Path.join(@test_workdir, "src/pkg/main.go"), "package pkg\n// mod")

      tasks = [make_task("test", inputs: ["**/*.go"])]

      {:ok, affected} = Delta.affected_tasks(tasks, path: @test_workdir)
      assert "test" in affected
    end

    test "matches * pattern" do
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      File.write!(Path.join(@test_workdir, "test.go"), "package main")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      File.write!(Path.join(@test_workdir, "main.go"), "package main\n// mod")

      tasks = [make_task("test", inputs: ["*.go"])]

      {:ok, affected} = Delta.affected_tasks(tasks, path: @test_workdir)
      assert "test" in affected
    end

    test "matches specific file" do
      File.write!(Path.join(@test_workdir, "go.mod"), "module test")
      File.write!(Path.join(@test_workdir, "main.go"), "package main")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      File.write!(Path.join(@test_workdir, "go.mod"), "module test\n// mod")

      tasks = [make_task("test", inputs: ["go.mod", "go.sum"])]

      {:ok, affected} = Delta.affected_tasks(tasks, path: @test_workdir)
      assert "test" in affected
    end
  end
end
