defmodule Sykli.SCM.GitHubTest do
  use ExUnit.Case, async: false

  describe "Sykli.GitHub.enabled?/0" do
    setup do
      saved =
        Enum.map(
          ["GITHUB_TOKEN", "GITHUB_REPOSITORY", "GITHUB_SHA"],
          fn var -> {var, System.get_env(var)} end
        )

      on_exit(fn ->
        Enum.each(saved, fn
          {var, nil} -> System.delete_env(var)
          {var, val} -> System.put_env(var, val)
        end)
      end)

      :ok
    end

    test "returns false when GITHUB_TOKEN is not set" do
      System.delete_env("GITHUB_TOKEN")
      System.put_env("GITHUB_REPOSITORY", "org/repo")
      System.put_env("GITHUB_SHA", "abc123")

      refute Sykli.GitHub.enabled?()
    end

    test "returns false when GITHUB_REPOSITORY is not set" do
      System.put_env("GITHUB_TOKEN", "ghp_test123")
      System.delete_env("GITHUB_REPOSITORY")
      System.put_env("GITHUB_SHA", "abc123")

      refute Sykli.GitHub.enabled?()
    end

    test "returns false when GITHUB_SHA is not set" do
      System.put_env("GITHUB_TOKEN", "ghp_test123")
      System.put_env("GITHUB_REPOSITORY", "org/repo")
      System.delete_env("GITHUB_SHA")

      refute Sykli.GitHub.enabled?()
    end

    test "returns true when all three env vars are set" do
      System.put_env("GITHUB_TOKEN", "ghp_test123")
      System.put_env("GITHUB_REPOSITORY", "org/repo")
      System.put_env("GITHUB_SHA", "abc123def456")

      assert Sykli.GitHub.enabled?()
    end

    test "returns false when no GitHub env vars are set" do
      System.delete_env("GITHUB_TOKEN")
      System.delete_env("GITHUB_REPOSITORY")
      System.delete_env("GITHUB_SHA")

      refute Sykli.GitHub.enabled?()
    end
  end

  describe "Sykli.SCM.GitHub delegates to Sykli.GitHub" do
    test "enabled?/0 delegates correctly" do
      # Both should return the same result
      assert Sykli.SCM.GitHub.enabled?() == Sykli.GitHub.enabled?()
    end
  end

  describe "Sykli.SCM.detect_provider/0" do
    setup do
      saved =
        Enum.map(
          [
            "GITHUB_TOKEN",
            "GITHUB_REPOSITORY",
            "GITHUB_SHA",
            "GITLAB_TOKEN",
            "CI_PROJECT_ID",
            "CI_COMMIT_SHA",
            "BITBUCKET_TOKEN",
            "BITBUCKET_REPO_FULL_NAME",
            "BITBUCKET_COMMIT"
          ],
          fn var -> {var, System.get_env(var)} end
        )

      on_exit(fn ->
        Enum.each(saved, fn
          {var, nil} -> System.delete_env(var)
          {var, val} -> System.put_env(var, val)
        end)
      end)

      # Clear all SCM env vars
      Enum.each(
        [
          "GITHUB_TOKEN",
          "GITHUB_REPOSITORY",
          "GITHUB_SHA",
          "GITLAB_TOKEN",
          "CI_PROJECT_ID",
          "CI_COMMIT_SHA",
          "BITBUCKET_TOKEN",
          "BITBUCKET_REPO_FULL_NAME",
          "BITBUCKET_COMMIT"
        ],
        &System.delete_env/1
      )

      :ok
    end

    test "returns nil when no provider is enabled" do
      assert Sykli.SCM.detect_provider() == nil
    end

    test "returns Sykli.SCM.GitHub when GitHub env vars are set" do
      System.put_env("GITHUB_TOKEN", "ghp_test")
      System.put_env("GITHUB_REPOSITORY", "org/repo")
      System.put_env("GITHUB_SHA", "abc123")

      assert Sykli.SCM.detect_provider() == Sykli.SCM.GitHub
    end

    test "enabled?/0 returns false when no provider configured" do
      refute Sykli.SCM.enabled?()
    end

    test "enabled?/0 returns true when a provider is configured" do
      System.put_env("GITHUB_TOKEN", "ghp_test")
      System.put_env("GITHUB_REPOSITORY", "org/repo")
      System.put_env("GITHUB_SHA", "abc123")

      assert Sykli.SCM.enabled?()
    end
  end
end
