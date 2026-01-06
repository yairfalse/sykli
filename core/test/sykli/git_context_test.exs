defmodule Sykli.GitContextTest do
  use ExUnit.Case, async: true

  alias Sykli.GitContext

  # ─────────────────────────────────────────────────────────────────────────────
  # DETECTION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "detect/1" do
    test "detects git context in current repo" do
      # This test runs in the sykli repo itself
      ctx = GitContext.detect(".")

      assert is_map(ctx)
      assert Map.has_key?(ctx, :url)
      assert Map.has_key?(ctx, :branch)
      assert Map.has_key?(ctx, :sha)
      assert Map.has_key?(ctx, :dirty)
    end

    test "returns sha as 40-character hex string" do
      ctx = GitContext.detect(".")

      assert is_binary(ctx.sha)
      assert String.length(ctx.sha) == 40
      assert Regex.match?(~r/^[0-9a-f]+$/, ctx.sha)
    end

    test "returns branch as string or nil for detached HEAD" do
      ctx = GitContext.detect(".")

      # Could be "main", feature branch, or nil (detached HEAD in CI)
      assert is_nil(ctx.branch) or is_binary(ctx.branch)

      if is_binary(ctx.branch) do
        assert String.length(ctx.branch) > 0
      end
    end

    test "returns dirty as boolean" do
      ctx = GitContext.detect(".")

      assert is_boolean(ctx.dirty)
    end

    test "returns error for non-git directory" do
      result = GitContext.detect("/tmp")

      assert {:error, :not_a_git_repo} = result
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # URL PARSING
  # ─────────────────────────────────────────────────────────────────────────────

  describe "parse_remote_url/1" do
    test "parses HTTPS URLs" do
      url = "https://github.com/org/repo.git"

      assert {:ok, parsed} = GitContext.parse_remote_url(url)
      assert parsed.protocol == :https
      assert parsed.host == "github.com"
      assert parsed.owner == "org"
      assert parsed.repo == "repo"
    end

    test "parses SSH URLs" do
      url = "git@github.com:org/repo.git"

      assert {:ok, parsed} = GitContext.parse_remote_url(url)
      assert parsed.protocol == :ssh
      assert parsed.host == "github.com"
      assert parsed.owner == "org"
      assert parsed.repo == "repo"
    end

    test "handles URLs without .git suffix" do
      url = "https://github.com/org/repo"

      assert {:ok, parsed} = GitContext.parse_remote_url(url)
      assert parsed.repo == "repo"
    end

    test "handles GitLab URLs" do
      url = "https://gitlab.com/group/subgroup/repo.git"

      assert {:ok, parsed} = GitContext.parse_remote_url(url)
      assert parsed.host == "gitlab.com"
      # GitLab can have nested groups
      assert parsed.owner == "group/subgroup"
      assert parsed.repo == "repo"
    end

    test "returns error for invalid URLs" do
      assert {:error, :invalid_url} = GitContext.parse_remote_url("not-a-url")
      assert {:error, :invalid_url} = GitContext.parse_remote_url("")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HTTPS CONVERSION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "to_https_url/1" do
    test "converts SSH URL to HTTPS" do
      ssh_url = "git@github.com:org/repo.git"

      assert {:ok, https_url} = GitContext.to_https_url(ssh_url)
      assert https_url == "https://github.com/org/repo.git"
    end

    test "keeps HTTPS URL unchanged" do
      https_url = "https://github.com/org/repo.git"

      assert {:ok, ^https_url} = GitContext.to_https_url(https_url)
    end

    test "handles GitLab SSH URLs" do
      ssh_url = "git@gitlab.com:group/repo.git"

      assert {:ok, https_url} = GitContext.to_https_url(ssh_url)
      assert https_url == "https://gitlab.com/group/repo.git"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CLONE COMMAND GENERATION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "clone_command/2" do
    test "generates shallow clone command" do
      ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: "abc123def456"
      }

      cmd = GitContext.clone_command(ctx, depth: 1)

      assert String.contains?(cmd, "git clone")
      assert String.contains?(cmd, "--depth=1")
      assert String.contains?(cmd, "--branch=main")
      assert String.contains?(cmd, "https://github.com/org/repo.git")
      assert String.contains?(cmd, "git checkout abc123def456")
    end

    test "defaults to shallow clone (depth 1) for speed" do
      ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: "abc123"
      }

      cmd = GitContext.clone_command(ctx, [])

      # Default is shallow clone for CI speed
      assert String.contains?(cmd, "--depth=1")
    end

    test "supports full clone with depth: :full option" do
      ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: "abc123"
      }

      cmd = GitContext.clone_command(ctx, depth: :full)

      refute String.contains?(cmd, "--depth")
    end

    test "handles detached HEAD (no branch)" do
      ctx = %{
        url: "https://github.com/org/repo.git",
        branch: nil,
        sha: "abc123"
      }

      cmd = GitContext.clone_command(ctx, depth: 1)

      # Should clone default branch then checkout SHA
      refute String.contains?(cmd, "--branch")
      assert String.contains?(cmd, "git checkout abc123")
    end
  end
end
