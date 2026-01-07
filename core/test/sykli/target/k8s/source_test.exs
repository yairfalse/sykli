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
end
