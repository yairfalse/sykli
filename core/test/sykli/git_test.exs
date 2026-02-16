defmodule Sykli.GitTest do
  use ExUnit.Case, async: false

  alias Sykli.Git

  @test_workdir Path.expand("/tmp/sykli_git_test")

  setup do
    File.rm_rf!(@test_workdir)
    File.mkdir_p!(@test_workdir)

    # Initialize git repo
    System.cmd("git", ["init", "-b", "main"], cd: @test_workdir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: @test_workdir)
    System.cmd("git", ["config", "user.name", "Test"], cd: @test_workdir)

    on_exit(fn ->
      File.rm_rf!(@test_workdir)
    end)

    :ok
  end

  describe "run/2" do
    test "returns output on success" do
      assert {:ok, output} = Git.run(["rev-parse", "--git-dir"], cd: @test_workdir)
      assert String.contains?(output, ".git")
    end

    test "returns error on git failure" do
      assert {:error, {:git_failed, _, code}} =
               Git.run(["rev-parse", "nonexistent"], cd: @test_workdir)

      assert code != 0
    end

    test "respects cd option" do
      assert {:ok, _} = Git.run(["status"], cd: @test_workdir)
    end

    test "returns error for invalid directory" do
      assert {:error, {:git_failed, _, _}} =
               Git.run(["status"], cd: "/nonexistent/path/#{System.unique_integer()}")
    end
  end

  describe "sha/1" do
    test "returns short SHA after commit" do
      File.write!(Path.join(@test_workdir, "test.txt"), "hello")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      assert {:ok, sha} = Git.sha(cd: @test_workdir)
      assert String.length(sha) >= 7
      assert Regex.match?(~r/^[a-f0-9]+$/, sha)
    end

    test "returns error when no commits" do
      assert {:error, {:git_failed, _, _}} = Git.sha(cd: @test_workdir)
    end
  end

  describe "branch/1" do
    test "returns branch name" do
      File.write!(Path.join(@test_workdir, "test.txt"), "hello")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      assert {:ok, "main"} = Git.branch(cd: @test_workdir)
    end

    test "returns nil for detached HEAD" do
      File.write!(Path.join(@test_workdir, "test.txt"), "hello")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      # Get the commit SHA and checkout detached
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: @test_workdir)
      System.cmd("git", ["checkout", String.trim(sha)], cd: @test_workdir, stderr_to_stdout: true)

      assert {:ok, nil} = Git.branch(cd: @test_workdir)
    end
  end

  describe "dirty?/1" do
    test "returns false for clean repo" do
      File.write!(Path.join(@test_workdir, "test.txt"), "hello")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      assert {:ok, false} = Git.dirty?(cd: @test_workdir)
    end

    test "returns true for uncommitted changes" do
      File.write!(Path.join(@test_workdir, "test.txt"), "hello")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      # Make a change
      File.write!(Path.join(@test_workdir, "test.txt"), "modified")

      assert {:ok, true} = Git.dirty?(cd: @test_workdir)
    end

    test "returns true for untracked files" do
      File.write!(Path.join(@test_workdir, "test.txt"), "hello")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "initial"], cd: @test_workdir)

      # Add untracked file
      File.write!(Path.join(@test_workdir, "new.txt"), "new file")

      assert {:ok, true} = Git.dirty?(cd: @test_workdir)
    end
  end

  describe "remote_url/1" do
    test "returns nil when no remote configured" do
      assert {:ok, nil} = Git.remote_url(cd: @test_workdir)
    end

    test "returns remote URL when configured" do
      System.cmd("git", ["remote", "add", "origin", "https://github.com/test/repo.git"],
        cd: @test_workdir
      )

      assert {:ok, "https://github.com/test/repo.git"} = Git.remote_url(cd: @test_workdir)
    end
  end

  describe "repo?/1" do
    test "returns true for git repository" do
      assert {:ok, true} = Git.repo?(cd: @test_workdir)
    end

    test "returns false for non-git directory" do
      non_git_dir = "/tmp/sykli_not_git_#{System.unique_integer([:positive])}"
      File.mkdir_p!(non_git_dir)

      on_exit(fn -> File.rm_rf!(non_git_dir) end)

      assert {:ok, false} = Git.repo?(cd: non_git_dir)
    end

    test "returns error for non-existent directory" do
      # Non-existent directory causes git to fail differently
      result = Git.repo?(cd: "/nonexistent/path/#{System.unique_integer()}")
      # Could be either {:ok, false} or an error depending on git version
      assert match?({:ok, false}, result) or match?({:error, _}, result)
    end
  end

  describe "timeout handling" do
    test "run/2 accepts timeout option" do
      # Just verify it doesn't crash with timeout option
      assert {:ok, _} = Git.run(["status"], cd: @test_workdir, timeout: 5000)
    end
  end

  describe "log_file/2" do
    test "returns recent commits for a file" do
      file = Path.join(@test_workdir, "tracked.txt")
      File.write!(file, "v1")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "add tracked.txt"], cd: @test_workdir)

      File.write!(file, "v2")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "update tracked.txt"], cd: @test_workdir)

      assert {:ok, commits} = Git.log_file("tracked.txt", cd: @test_workdir)
      assert length(commits) == 2

      [latest | _] = commits
      assert latest.message == "update tracked.txt"
      assert latest.author == "Test"
      assert is_binary(latest.sha)
      assert String.length(latest.sha) == 40
      assert is_binary(latest.date)
    end

    test "returns empty list for untracked file" do
      # Need at least one commit for git log to work
      File.write!(Path.join(@test_workdir, "init.txt"), "init")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "init"], cd: @test_workdir)

      assert {:ok, []} = Git.log_file("nonexistent.txt", cd: @test_workdir)
    end

    test "respects limit option" do
      file = Path.join(@test_workdir, "multi.txt")

      for i <- 1..5 do
        File.write!(file, "v#{i}")
        System.cmd("git", ["add", "."], cd: @test_workdir)
        System.cmd("git", ["commit", "-m", "commit #{i}"], cd: @test_workdir)
      end

      assert {:ok, commits} = Git.log_file("multi.txt", cd: @test_workdir, limit: 2)
      assert length(commits) == 2
    end
  end

  describe "blame_line/3" do
    test "returns blame info for a specific line" do
      file = Path.join(@test_workdir, "blame_test.txt")
      File.write!(file, "line one\nline two\nline three\n")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "add blame_test"], cd: @test_workdir)

      assert {:ok, blame} = Git.blame_line("blame_test.txt", 2, cd: @test_workdir)
      assert blame.author == "Test"
      assert blame.message == "add blame_test"
      assert is_binary(blame.sha)
      assert String.length(blame.sha) == 40
      assert is_binary(blame.date)
    end

    test "returns error for non-existent file" do
      File.write!(Path.join(@test_workdir, "dummy.txt"), "x")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "init"], cd: @test_workdir)

      assert {:error, _} = Git.blame_line("no_such_file.txt", 1, cd: @test_workdir)
    end

    test "returns error for out-of-range line" do
      file = Path.join(@test_workdir, "short.txt")
      File.write!(file, "only one line\n")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "add short"], cd: @test_workdir)

      assert {:error, _} = Git.blame_line("short.txt", 999, cd: @test_workdir)
    end

    test "handles multi-word author names correctly" do
      System.cmd("git", ["config", "user.name", "Alice Bob Carol"], cd: @test_workdir)

      file = Path.join(@test_workdir, "multiword.txt")
      File.write!(file, "hello world\n")
      System.cmd("git", ["add", "."], cd: @test_workdir)
      System.cmd("git", ["commit", "-m", "multi-word author"], cd: @test_workdir)

      assert {:ok, blame} = Git.blame_line("multiword.txt", 1, cd: @test_workdir)
      assert blame.author == "Alice Bob Carol"
      assert blame.message == "multi-word author"
    end
  end
end
