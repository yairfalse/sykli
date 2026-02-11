defmodule Sykli.Occurrence.GitContextTest do
  use ExUnit.Case, async: true

  alias Sykli.Occurrence.GitContext

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "git_ctx_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, workdir: test_dir}
  end

  describe "collect/1" do
    test "returns map with expected keys from a git repo" do
      workdir = init_git_repo()

      result = GitContext.collect(workdir)

      assert is_map(result)
      assert Map.has_key?(result, "sha")
      assert Map.has_key?(result, "branch")
      assert Map.has_key?(result, "recent_commits")
      assert Map.has_key?(result, "changed_files")
    end

    test "returns sha and branch from a git repo" do
      workdir = init_git_repo()

      result = GitContext.collect(workdir)

      assert is_binary(result["sha"])
      assert String.length(result["sha"]) > 0
      # Default branch after git init + commit
      assert result["branch"] in ["main", "master"]
    end

    test "returns recent commits" do
      workdir = init_git_repo()

      result = GitContext.collect(workdir)

      assert is_list(result["recent_commits"])
      assert length(result["recent_commits"]) >= 1

      commit = hd(result["recent_commits"])
      assert is_binary(commit["sha"])
      assert is_binary(commit["message"])
      assert is_binary(commit["author"])
    end

    test "returns changed files for dirty workdir" do
      workdir = init_git_repo()

      # Create an uncommitted file
      File.write!(Path.join(workdir, "new_file.txt"), "hello")

      result = GitContext.collect(workdir)

      assert "new_file.txt" in result["changed_files"]
    end

    test "degrades gracefully when not in git repo", %{workdir: workdir} do
      result = GitContext.collect(workdir)

      assert result["sha"] == nil
      assert result["branch"] == nil
      assert result["recent_commits"] == []
      assert result["changed_files"] == []
    end
  end

  describe "recent_commits/2" do
    test "respects limit" do
      workdir = init_git_repo()

      # Add more commits
      for i <- 1..5 do
        File.write!(Path.join(workdir, "file#{i}.txt"), "content #{i}")
        System.cmd("git", ["add", "."], cd: workdir)
        System.cmd("git", ["commit", "-m", "commit #{i}"], cd: workdir)
      end

      commits = GitContext.recent_commits(workdir, 3)
      assert length(commits) == 3
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp init_git_repo do
    dir = Path.join(@tmp_dir, "git_repo_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    System.cmd("git", ["init"], cd: dir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    File.write!(Path.join(dir, "README.md"), "test")
    System.cmd("git", ["add", "."], cd: dir)
    System.cmd("git", ["commit", "-m", "initial"], cd: dir)

    dir
  end
end
