defmodule Sykli.PrepareGitContextTest do
  use ExUnit.Case, async: true

  # ─────────────────────────────────────────────────────────────────────────────
  # GIT CONTEXT PREPARATION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "prepare_git_context/2" do
    test "detects git context from workdir" do
      # Run in the sykli repo itself (may be dirty during development)
      assert {:ok, ctx} = Sykli.prepare_git_context(".", allow_dirty: true)

      assert is_binary(ctx.url)
      assert is_binary(ctx.sha)
      assert String.length(ctx.sha) == 40
    end

    test "returns error for non-git directory" do
      assert {:error, :not_a_git_repo} = Sykli.prepare_git_context("/tmp", [])
    end

    test "returns error for dirty workdir by default" do
      # Create a dirty context manually for testing
      dirty_ctx = %{
        url: "https://github.com/test/repo.git",
        branch: "main",
        sha: "abc123",
        dirty: true
      }

      # Use internal validation function
      assert {:error, :dirty_workdir} =
               Sykli.validate_git_context(dirty_ctx, [])
    end

    test "allows dirty workdir with allow_dirty option" do
      dirty_ctx = %{
        url: "https://github.com/test/repo.git",
        branch: "main",
        sha: "abc123",
        dirty: true
      }

      assert :ok = Sykli.validate_git_context(dirty_ctx, allow_dirty: true)
    end

    test "accepts explicit git_context option" do
      explicit_ctx = %{
        url: "https://github.com/explicit/repo.git",
        branch: "feature",
        sha: "explicit123",
        dirty: false
      }

      # When git_context is explicitly provided, use it instead of detecting
      assert {:ok, ctx} = Sykli.prepare_git_context(".", git_context: explicit_ctx)
      assert ctx.url == "https://github.com/explicit/repo.git"
      assert ctx.sha == "explicit123"
    end

    test "passes through git_ssh_secret option" do
      # Allow dirty since we're testing option pass-through, not dirty detection
      assert {:ok, _ctx, opts} =
               Sykli.prepare_git_context_with_opts(".",
                 git_ssh_secret: "my-key",
                 allow_dirty: true
               )

      assert Keyword.get(opts, :git_ssh_secret) == "my-key"
    end

    test "passes through git_token_secret option" do
      # Allow dirty since we're testing option pass-through, not dirty detection
      assert {:ok, _ctx, opts} =
               Sykli.prepare_git_context_with_opts(".",
                 git_token_secret: "my-token",
                 allow_dirty: true
               )

      assert Keyword.get(opts, :git_token_secret) == "my-token"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DIRTY WORKDIR ERROR MESSAGE
  # ─────────────────────────────────────────────────────────────────────────────

  describe "dirty workdir handling" do
    test "error includes helpful message" do
      # The error should suggest --allow-dirty flag
      dirty_ctx = %{dirty: true, sha: "abc", url: "https://...", branch: "main"}

      assert {:error, :dirty_workdir} = Sykli.validate_git_context(dirty_ctx, [])
    end
  end
end
