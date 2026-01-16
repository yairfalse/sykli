defmodule Sykli.Target.K8s.SourceTest do
  use ExUnit.Case, async: true

  alias Sykli.Target.K8s.Source

  # ─────────────────────────────────────────────────────────────────────────────
  # INIT CONTAINER BUILDING
  # ─────────────────────────────────────────────────────────────────────────────

  describe "build_init_container/2" do
    # Use valid 7+ char hex SHA for all tests
    @valid_sha "abc123def456789"

    test "builds git clone init container" do
      git_ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: @valid_sha
      }

      container = Source.build_init_container(git_ctx, [])

      assert container["name"] == "git-clone"
      assert container["image"] == "alpine/git:latest"
      assert is_list(container["command"])
      assert is_list(container["volumeMounts"])

      # Should mount workspace
      mount = Enum.find(container["volumeMounts"], &(&1["name"] == "workspace"))
      assert mount["mountPath"] == "/workspace"
    end

    test "includes git URL in command" do
      git_ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: @valid_sha
      }

      container = Source.build_init_container(git_ctx, [])

      command_str = Enum.at(container["command"], 2)
      # URL is now quoted
      assert String.contains?(command_str, "'https://github.com/org/repo.git'")
    end

    test "includes SHA checkout in command" do
      git_ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: "abc123def456"
      }

      container = Source.build_init_container(git_ctx, [])

      command_str = Enum.at(container["command"], 2)
      # SHA is now quoted
      assert String.contains?(command_str, "git checkout 'abc123def456'")
    end

    test "uses shallow clone by default" do
      git_ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: @valid_sha
      }

      container = Source.build_init_container(git_ctx, [])

      command_str = Enum.at(container["command"], 2)
      assert String.contains?(command_str, "--depth=1")
    end

    test "respects custom depth option" do
      git_ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: @valid_sha
      }

      container = Source.build_init_container(git_ctx, depth: 10)

      command_str = Enum.at(container["command"], 2)
      assert String.contains?(command_str, "--depth=10")
    end

    test "respects full clone option" do
      git_ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: @valid_sha
      }

      container = Source.build_init_container(git_ctx, depth: :full)

      command_str = Enum.at(container["command"], 2)
      refute String.contains?(command_str, "--depth")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SSH KEY AUTHENTICATION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "build_init_container/2 with SSH auth" do
    @valid_sha "abc123def456789"

    test "adds SSH key setup when secret specified" do
      git_ctx = %{
        url: "git@github.com:org/private-repo.git",
        branch: "main",
        sha: @valid_sha
      }

      container = Source.build_init_container(git_ctx, git_ssh_secret: "git-ssh-key")

      # Should have env var for SSH key
      env = container["env"] || []
      ssh_key_env = Enum.find(env, &(&1["name"] == "GIT_SSH_KEY"))
      assert ssh_key_env != nil
      assert ssh_key_env["valueFrom"]["secretKeyRef"]["name"] == "git-ssh-key"

      # Command should set up SSH
      command_str = Enum.at(container["command"], 2)
      assert String.contains?(command_str, "mkdir -p ~/.ssh")
      assert String.contains?(command_str, "ssh-keyscan")
    end

    test "converts SSH URL to use SSH protocol" do
      git_ctx = %{
        url: "git@github.com:org/repo.git",
        branch: "main",
        sha: @valid_sha
      }

      container = Source.build_init_container(git_ctx, git_ssh_secret: "key")

      command_str = Enum.at(container["command"], 2)
      # Should use SSH URL (quoted), not HTTPS
      assert String.contains?(command_str, "'git@github.com:org/repo.git'")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HTTPS TOKEN AUTHENTICATION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "build_init_container/2 with token auth" do
    @valid_sha "abc123def456789"

    test "embeds token in URL when secret specified" do
      git_ctx = %{
        url: "https://github.com/org/private-repo.git",
        branch: "main",
        sha: @valid_sha
      }

      container = Source.build_init_container(git_ctx, git_token_secret: "git-token")

      # Should have env var for token
      env = container["env"] || []
      token_env = Enum.find(env, &(&1["name"] == "GIT_TOKEN"))
      assert token_env != nil
      assert token_env["valueFrom"]["secretKeyRef"]["name"] == "git-token"

      # Command should use token in URL (not quoted because of shell expansion)
      command_str = Enum.at(container["command"], 2)
      assert String.contains?(command_str, "https://${GIT_TOKEN}@github.com")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VOLUME DEFINITIONS
  # ─────────────────────────────────────────────────────────────────────────────

  describe "workspace_volume/0" do
    test "returns emptyDir volume for workspace" do
      volume = Source.workspace_volume()

      assert volume["name"] == "workspace"
      assert volume["emptyDir"] == %{}
    end
  end

  describe "workspace_mount/1" do
    test "returns volume mount for workspace" do
      mount = Source.workspace_mount("/app")

      assert mount["name"] == "workspace"
      assert mount["mountPath"] == "/app"
    end

    test "defaults to /workspace path" do
      mount = Source.workspace_mount()

      assert mount["mountPath"] == "/workspace"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # STRATEGY SELECTION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "strategy/1" do
    test "defaults to git_clone" do
      assert Source.strategy([]) == :git_clone
    end

    test "respects explicit strategy option" do
      assert Source.strategy(source_strategy: :pvc) == :pvc
      assert Source.strategy(source_strategy: :git_clone) == :git_clone
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DIRTY WORKDIR HANDLING
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate_git_context/2" do
    test "returns ok for clean workdir" do
      ctx = %{dirty: false, sha: "abc123", url: "https://...", branch: "main"}

      assert :ok = Source.validate_git_context(ctx, [])
    end

    test "returns error for dirty workdir by default" do
      ctx = %{dirty: true, sha: "abc123", url: "https://...", branch: "main"}

      assert {:error, :dirty_workdir} = Source.validate_git_context(ctx, [])
    end

    test "allows dirty workdir with allow_dirty option" do
      ctx = %{dirty: true, sha: "abc123", url: "https://...", branch: "main"}

      assert :ok = Source.validate_git_context(ctx, allow_dirty: true)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SHELL INJECTION PREVENTION (Security tests for issue #55)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "validate_shell_safe/2" do
    test "accepts valid SHA (7+ hex chars)" do
      assert {:ok, "abc123f"} = Source.validate_shell_safe("abc123f", :sha)

      assert {:ok, "abc123def456789012345678901234567890abcd"} =
               Source.validate_shell_safe("abc123def456789012345678901234567890abcd", :sha)
    end

    test "rejects SHA with shell metacharacters" do
      assert {:error, {:invalid_chars, :sha, _}} =
               Source.validate_shell_safe("abc123;rm -rf /", :sha)

      assert {:error, {:invalid_chars, :sha, _}} =
               Source.validate_shell_safe("abc123`whoami`", :sha)

      assert {:error, {:invalid_chars, :sha, _}} =
               Source.validate_shell_safe("abc123$(cat /etc/passwd)", :sha)
    end

    test "accepts valid branch names" do
      assert {:ok, "main"} = Source.validate_shell_safe("main", :branch)
      assert {:ok, "feature/new-thing"} = Source.validate_shell_safe("feature/new-thing", :branch)
      assert {:ok, "release-1.0.0"} = Source.validate_shell_safe("release-1.0.0", :branch)
    end

    test "rejects branch with shell metacharacters" do
      assert {:error, {:invalid_chars, :branch, _}} =
               Source.validate_shell_safe("main;rm -rf /", :branch)

      assert {:error, {:invalid_chars, :branch, _}} =
               Source.validate_shell_safe("main`id`", :branch)

      assert {:error, {:invalid_chars, :branch, _}} =
               Source.validate_shell_safe("main$(whoami)", :branch)

      assert {:error, {:invalid_chars, :branch, _}} =
               Source.validate_shell_safe("main && evil", :branch)
    end

    test "accepts valid hostnames" do
      assert {:ok, "github.com"} = Source.validate_shell_safe("github.com", :host)
      assert {:ok, "gitlab.example.org"} = Source.validate_shell_safe("gitlab.example.org", :host)
    end

    test "rejects hostname with shell metacharacters" do
      assert {:error, {:invalid_chars, :host, _}} =
               Source.validate_shell_safe("evil.com;rm -rf /", :host)

      assert {:error, {:invalid_chars, :host, _}} =
               Source.validate_shell_safe("evil.com:org/repo", :host)
    end

    test "accepts valid paths" do
      assert {:ok, "/workspace"} = Source.validate_shell_safe("/workspace", :path)
      assert {:ok, "/app/src"} = Source.validate_shell_safe("/app/src", :path)
    end

    test "rejects path with shell metacharacters" do
      assert {:error, {:invalid_chars, :path, _}} =
               Source.validate_shell_safe("/workspace;id", :path)

      assert {:error, {:invalid_chars, :path, _}} =
               Source.validate_shell_safe("/workspace$(whoami)", :path)
    end

    test "accepts nil values" do
      assert {:ok, nil} = Source.validate_shell_safe(nil, :branch)
    end
  end

  describe "validate_git_url/1" do
    test "accepts valid HTTPS URLs" do
      assert {:ok, _} = Source.validate_git_url("https://github.com/org/repo.git")
      assert {:ok, _} = Source.validate_git_url("https://gitlab.com/group/subgroup/repo.git")
    end

    test "accepts valid SSH URLs" do
      assert {:ok, _} = Source.validate_git_url("git@github.com:org/repo.git")
      assert {:ok, _} = Source.validate_git_url("git@gitlab.com:group/repo.git")
    end

    test "rejects URLs with shell injection in SSH format" do
      # This is the attack vector from issue #55
      assert {:error, {:invalid_url, _}} =
               Source.validate_git_url("git@evil.com;rm -rf /:org/repo.git")
    end

    test "rejects URLs with command substitution" do
      assert {:error, {:invalid_url, _}} =
               Source.validate_git_url("https://github.com/$(whoami)/repo.git")

      assert {:error, {:invalid_url, _}} =
               Source.validate_git_url("git@github.com:`id`:repo.git")
    end

    test "rejects URLs with semicolons" do
      assert {:error, {:invalid_url, _}} =
               Source.validate_git_url("https://github.com/org/repo.git;evil")
    end

    test "rejects unsupported URL schemes" do
      assert {:error, {:invalid_url, _}} = Source.validate_git_url("file:///etc/passwd")
      assert {:error, {:invalid_url, _}} = Source.validate_git_url("ftp://evil.com/repo")
    end

    test "accepts nil" do
      assert {:ok, nil} = Source.validate_git_url(nil)
    end
  end

  describe "build_init_container/2 shell injection prevention" do
    test "raises on malicious SHA" do
      git_ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: "abc123;rm -rf /"
      }

      assert_raise RuntimeError, ~r/Invalid git SHA/, fn ->
        Source.build_init_container(git_ctx, [])
      end
    end

    test "raises on malicious branch" do
      git_ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main$(whoami)",
        sha: "abc123def456"
      }

      assert_raise RuntimeError, ~r/Invalid branch name/, fn ->
        Source.build_init_container(git_ctx, [])
      end
    end

    test "raises on malicious URL" do
      git_ctx = %{
        url: "git@evil.com;cat /etc/passwd:org/repo.git",
        branch: "main",
        sha: "abc123def456"
      }

      assert_raise RuntimeError, ~r/Invalid git URL/, fn ->
        Source.build_init_container(git_ctx, [])
      end
    end

    test "raises on command substitution in URL" do
      git_ctx = %{
        url: "https://github.com/$(id)/repo.git",
        branch: "main",
        sha: "abc123def456"
      }

      assert_raise RuntimeError, ~r/Invalid git URL/, fn ->
        Source.build_init_container(git_ctx, [])
      end
    end
  end
end
