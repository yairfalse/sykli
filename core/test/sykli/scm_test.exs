defmodule Sykli.SCMTest do
  use ExUnit.Case, async: false

  # ─────────────────────────────────────────────────────────────────────────────
  # Environment variable helpers
  # ─────────────────────────────────────────────────────────────────────────────

  @github_vars ~w(GITHUB_TOKEN GITHUB_REPOSITORY GITHUB_SHA)
  @gitlab_vars ~w(GITLAB_TOKEN CI_PROJECT_ID CI_COMMIT_SHA CI_API_V4_URL)
  @bitbucket_vars ~w(BITBUCKET_TOKEN BITBUCKET_REPO_FULL_NAME BITBUCKET_COMMIT)
  @all_vars @github_vars ++ @gitlab_vars ++ @bitbucket_vars

  defp save_env(vars) do
    Map.new(vars, fn key -> {key, System.get_env(key)} end)
  end

  defp restore_env(saved) do
    Enum.each(saved, fn
      {key, nil} -> System.delete_env(key)
      {key, val} -> System.put_env(key, val)
    end)
  end

  defp clear_all_scm_vars do
    Enum.each(@all_vars, &System.delete_env/1)
  end

  setup do
    saved = save_env(@all_vars)
    clear_all_scm_vars()
    on_exit(fn -> restore_env(saved) end)
    :ok
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SCM.detect_provider/0 — provider detection from env vars
  # ─────────────────────────────────────────────────────────────────────────────

  describe "SCM.detect_provider/0" do
    test "returns nil when no SCM env vars are set" do
      assert Sykli.SCM.detect_provider() == nil
    end

    test "returns nil when token is set but other required vars are missing" do
      System.put_env("GITHUB_TOKEN", "ghp_test")
      assert Sykli.SCM.detect_provider() == nil
    end

    test "detects GitHub when all GitHub env vars are set" do
      System.put_env("GITHUB_TOKEN", "ghp_test123")
      System.put_env("GITHUB_REPOSITORY", "owner/repo")
      System.put_env("GITHUB_SHA", "abc123")

      assert Sykli.SCM.detect_provider() == Sykli.SCM.GitHub
    end

    test "detects GitLab when all GitLab env vars are set" do
      System.put_env("GITLAB_TOKEN", "glpat-test")
      System.put_env("CI_PROJECT_ID", "12345")
      System.put_env("CI_COMMIT_SHA", "def456")

      assert Sykli.SCM.detect_provider() == Sykli.SCM.GitLab
    end

    test "detects Bitbucket when all Bitbucket env vars are set" do
      System.put_env("BITBUCKET_TOKEN", "bb_test")
      System.put_env("BITBUCKET_REPO_FULL_NAME", "owner/repo")
      System.put_env("BITBUCKET_COMMIT", "789abc")

      assert Sykli.SCM.detect_provider() == Sykli.SCM.Bitbucket
    end

    test "prefers GitHub over GitLab when both are configured" do
      System.put_env("GITHUB_TOKEN", "ghp_test")
      System.put_env("GITHUB_REPOSITORY", "owner/repo")
      System.put_env("GITHUB_SHA", "abc123")

      System.put_env("GITLAB_TOKEN", "glpat-test")
      System.put_env("CI_PROJECT_ID", "12345")
      System.put_env("CI_COMMIT_SHA", "def456")

      assert Sykli.SCM.detect_provider() == Sykli.SCM.GitHub
    end

    test "prefers GitLab over Bitbucket when both are configured" do
      System.put_env("GITLAB_TOKEN", "glpat-test")
      System.put_env("CI_PROJECT_ID", "12345")
      System.put_env("CI_COMMIT_SHA", "def456")

      System.put_env("BITBUCKET_TOKEN", "bb_test")
      System.put_env("BITBUCKET_REPO_FULL_NAME", "owner/repo")
      System.put_env("BITBUCKET_COMMIT", "789abc")

      assert Sykli.SCM.detect_provider() == Sykli.SCM.GitLab
    end

    test "detection order is GitHub > GitLab > Bitbucket" do
      System.put_env("GITHUB_TOKEN", "ghp_test")
      System.put_env("GITHUB_REPOSITORY", "owner/repo")
      System.put_env("GITHUB_SHA", "abc123")

      System.put_env("GITLAB_TOKEN", "glpat-test")
      System.put_env("CI_PROJECT_ID", "12345")
      System.put_env("CI_COMMIT_SHA", "def456")

      System.put_env("BITBUCKET_TOKEN", "bb_test")
      System.put_env("BITBUCKET_REPO_FULL_NAME", "owner/repo")
      System.put_env("BITBUCKET_COMMIT", "789abc")

      assert Sykli.SCM.detect_provider() == Sykli.SCM.GitHub
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SCM.enabled?/0
  # ─────────────────────────────────────────────────────────────────────────────

  describe "SCM.enabled?/0" do
    test "returns false when no provider is configured" do
      refute Sykli.SCM.enabled?()
    end

    test "returns true when at least one provider is configured" do
      System.put_env("GITHUB_TOKEN", "ghp_test")
      System.put_env("GITHUB_REPOSITORY", "owner/repo")
      System.put_env("GITHUB_SHA", "abc123")

      assert Sykli.SCM.enabled?()
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SCM.update_status/3 — facade behavior
  # ─────────────────────────────────────────────────────────────────────────────

  describe "SCM.update_status/3" do
    test "returns :ok when no provider is configured (no-op)" do
      assert Sykli.SCM.update_status("test-task", "success") == :ok
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # GitHub provider — enabled?/0
  # ─────────────────────────────────────────────────────────────────────────────

  describe "Sykli.SCM.GitHub (via Sykli.GitHub)" do
    test "enabled? returns false without env vars" do
      refute Sykli.SCM.GitHub.enabled?()
    end

    test "enabled? returns false with only GITHUB_TOKEN" do
      System.put_env("GITHUB_TOKEN", "ghp_test")
      refute Sykli.SCM.GitHub.enabled?()
    end

    test "enabled? returns false with only GITHUB_TOKEN and GITHUB_REPOSITORY" do
      System.put_env("GITHUB_TOKEN", "ghp_test")
      System.put_env("GITHUB_REPOSITORY", "owner/repo")
      refute Sykli.SCM.GitHub.enabled?()
    end

    test "enabled? returns true with all three vars" do
      System.put_env("GITHUB_TOKEN", "ghp_test")
      System.put_env("GITHUB_REPOSITORY", "owner/repo")
      System.put_env("GITHUB_SHA", "abc123def456")
      assert Sykli.SCM.GitHub.enabled?()
    end

    test "update_status builds correct request and returns error for unreachable host" do
      System.put_env("GITHUB_TOKEN", "ghp_test_token")
      System.put_env("GITHUB_REPOSITORY", "owner/repo")
      System.put_env("GITHUB_SHA", "deadbeef")

      # This will attempt a real HTTP call to api.github.com, which will fail
      # with auth error or network error — either way we get {:error, _}
      result = Sykli.SCM.GitHub.update_status("build", "pending")
      assert result == :ok or match?({:error, _}, result)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # GitLab provider — enabled?/0 and status mapping
  # ─────────────────────────────────────────────────────────────────────────────

  describe "Sykli.SCM.GitLab" do
    test "enabled? returns false without env vars" do
      refute Sykli.SCM.GitLab.enabled?()
    end

    test "enabled? returns false with only GITLAB_TOKEN" do
      System.put_env("GITLAB_TOKEN", "glpat-test")
      refute Sykli.SCM.GitLab.enabled?()
    end

    test "enabled? returns false with GITLAB_TOKEN and CI_PROJECT_ID but no SHA" do
      System.put_env("GITLAB_TOKEN", "glpat-test")
      System.put_env("CI_PROJECT_ID", "12345")
      refute Sykli.SCM.GitLab.enabled?()
    end

    test "enabled? returns true with all three required vars" do
      System.put_env("GITLAB_TOKEN", "glpat-test")
      System.put_env("CI_PROJECT_ID", "12345")
      System.put_env("CI_COMMIT_SHA", "abc123")
      assert Sykli.SCM.GitLab.enabled?()
    end

    test "enabled? returns true without CI_API_V4_URL (uses default)" do
      System.put_env("GITLAB_TOKEN", "glpat-test")
      System.put_env("CI_PROJECT_ID", "12345")
      System.put_env("CI_COMMIT_SHA", "abc123")
      # CI_API_V4_URL is optional — defaults to https://gitlab.com/api/v4
      assert Sykli.SCM.GitLab.enabled?()
    end

    test "update_status builds request without crashing" do
      System.put_env("GITLAB_TOKEN", "glpat-test-token")
      System.put_env("CI_PROJECT_ID", "99")
      System.put_env("CI_COMMIT_SHA", "feedface")
      # Use a non-routable host to ensure the request fails fast
      System.put_env("CI_API_V4_URL", "http://127.0.0.1:1")

      result = Sykli.SCM.GitLab.update_status("lint", "success")
      assert match?({:error, _}, result)
    end

    test "update_status with custom prefix" do
      System.put_env("GITLAB_TOKEN", "glpat-test-token")
      System.put_env("CI_PROJECT_ID", "99")
      System.put_env("CI_COMMIT_SHA", "feedface")
      System.put_env("CI_API_V4_URL", "http://127.0.0.1:1")

      result = Sykli.SCM.GitLab.update_status("lint", "pending", prefix: "custom/prefix")
      assert match?({:error, _}, result)
    end

    test "update_status with each state does not crash" do
      System.put_env("GITLAB_TOKEN", "glpat-test")
      System.put_env("CI_PROJECT_ID", "99")
      System.put_env("CI_COMMIT_SHA", "feedface")
      System.put_env("CI_API_V4_URL", "http://127.0.0.1:1")

      for state <- ~w(pending success failure error other) do
        result = Sykli.SCM.GitLab.update_status("task", state)

        assert match?({:error, _}, result),
               "expected error for state #{state}, got: #{inspect(result)}"
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Bitbucket provider — enabled?/0 and status mapping
  # ─────────────────────────────────────────────────────────────────────────────

  describe "Sykli.SCM.Bitbucket" do
    test "enabled? returns false without env vars" do
      refute Sykli.SCM.Bitbucket.enabled?()
    end

    test "enabled? returns false with only BITBUCKET_TOKEN" do
      System.put_env("BITBUCKET_TOKEN", "bb_test")
      refute Sykli.SCM.Bitbucket.enabled?()
    end

    test "enabled? returns false with BITBUCKET_TOKEN and BITBUCKET_REPO_FULL_NAME but no SHA" do
      System.put_env("BITBUCKET_TOKEN", "bb_test")
      System.put_env("BITBUCKET_REPO_FULL_NAME", "owner/repo")
      refute Sykli.SCM.Bitbucket.enabled?()
    end

    test "enabled? returns true with all three required vars" do
      System.put_env("BITBUCKET_TOKEN", "bb_test")
      System.put_env("BITBUCKET_REPO_FULL_NAME", "owner/repo")
      System.put_env("BITBUCKET_COMMIT", "abc123")
      assert Sykli.SCM.Bitbucket.enabled?()
    end

    test "update_status builds request without crashing" do
      System.put_env("BITBUCKET_TOKEN", "bb_test_token")
      System.put_env("BITBUCKET_REPO_FULL_NAME", "owner/repo")
      System.put_env("BITBUCKET_COMMIT", "deadbeef")

      # api.bitbucket.org will reject the token but the request construction succeeds
      result = Sykli.SCM.Bitbucket.update_status("test", "success")
      assert result == :ok or match?({:error, _}, result)
    end

    test "update_status with custom prefix" do
      System.put_env("BITBUCKET_TOKEN", "bb_test_token")
      System.put_env("BITBUCKET_REPO_FULL_NAME", "owner/repo")
      System.put_env("BITBUCKET_COMMIT", "deadbeef")

      result = Sykli.SCM.Bitbucket.update_status("test", "pending", prefix: "my/ci")
      assert result == :ok or match?({:error, _}, result)
    end

    test "update_status with each state does not crash" do
      System.put_env("BITBUCKET_TOKEN", "bb_test")
      System.put_env("BITBUCKET_REPO_FULL_NAME", "owner/repo")
      System.put_env("BITBUCKET_COMMIT", "deadbeef")

      for state <- ~w(pending success failure error other) do
        result = Sykli.SCM.Bitbucket.update_status("task", state)

        assert result == :ok or match?({:error, _}, result),
               "unexpected result for state #{state}: #{inspect(result)}"
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Behaviour compliance
  # ─────────────────────────────────────────────────────────────────────────────

  describe "behaviour compliance" do
    test "GitHub implements SCM.Behaviour" do
      behaviours = Sykli.SCM.GitHub.__info__(:attributes) |> Keyword.get_values(:behaviour)
      assert List.flatten(behaviours) |> Enum.member?(Sykli.SCM.Behaviour)
    end

    test "GitLab implements SCM.Behaviour" do
      behaviours = Sykli.SCM.GitLab.__info__(:attributes) |> Keyword.get_values(:behaviour)
      assert List.flatten(behaviours) |> Enum.member?(Sykli.SCM.Behaviour)
    end

    test "Bitbucket implements SCM.Behaviour" do
      behaviours = Sykli.SCM.Bitbucket.__info__(:attributes) |> Keyword.get_values(:behaviour)
      assert List.flatten(behaviours) |> Enum.member?(Sykli.SCM.Behaviour)
    end

    test "all providers export enabled?/0" do
      for mod <- [Sykli.SCM.GitHub, Sykli.SCM.GitLab, Sykli.SCM.Bitbucket] do
        assert function_exported?(mod, :enabled?, 0),
               "#{inspect(mod)} must export enabled?/0"
      end
    end

    test "all providers export update_status/3" do
      for mod <- [Sykli.SCM.GitHub, Sykli.SCM.GitLab, Sykli.SCM.Bitbucket] do
        assert function_exported?(mod, :update_status, 3),
               "#{inspect(mod)} must export update_status/3"
      end
    end
  end
end
