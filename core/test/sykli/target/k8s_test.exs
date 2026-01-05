defmodule Sykli.Target.K8sTest do
  use ExUnit.Case, async: true

  alias Sykli.Target.K8s
  alias Sykli.Target.K8sOptions

  # ─────────────────────────────────────────────────────────────────────────────
  # JOB MANIFEST BUILDING - GIT CLONE INIT CONTAINER
  # ─────────────────────────────────────────────────────────────────────────────

  describe "build_job_manifest/4 with git context" do
    setup do
      task = %Sykli.Graph.Task{
        name: "build",
        command: "cargo build --release",
        container: "rust:latest",
        k8s: %K8sOptions{}
      }

      state = %K8s{
        namespace: "sykli-test",
        auth_config: %{},
        artifact_pvc: "sykli-artifacts",
        in_cluster: false
      }

      git_ctx = %{
        url: "https://github.com/org/repo.git",
        branch: "main",
        sha: "abc123def456789",
        dirty: false
      }

      %{task: task, state: state, git_ctx: git_ctx}
    end

    test "includes git clone init container when git_context provided", ctx do
      opts = [git_context: ctx.git_ctx]

      manifest = K8s.build_job_manifest(ctx.task, "sykli-build-1234", ctx.state, opts)

      pod_spec = manifest["spec"]["template"]["spec"]
      init_containers = pod_spec["initContainers"] || []

      # Should have git-clone init container
      git_clone = Enum.find(init_containers, &(&1["name"] == "git-clone"))
      assert git_clone != nil
      assert git_clone["image"] == "alpine/git:latest"

      # Command should include clone and checkout
      command_str = Enum.at(git_clone["command"], 2)
      assert String.contains?(command_str, "git clone")
      assert String.contains?(command_str, "https://github.com/org/repo.git")
      assert String.contains?(command_str, "git checkout abc123def456789")
    end

    test "includes workspace volume when git_context provided", ctx do
      opts = [git_context: ctx.git_ctx]

      manifest = K8s.build_job_manifest(ctx.task, "sykli-build-1234", ctx.state, opts)

      pod_spec = manifest["spec"]["template"]["spec"]
      volumes = pod_spec["volumes"] || []

      workspace_vol = Enum.find(volumes, &(&1["name"] == "workspace"))
      assert workspace_vol != nil
      assert workspace_vol["emptyDir"] == %{}
    end

    test "mounts workspace to main container when git_context provided", ctx do
      opts = [git_context: ctx.git_ctx]

      manifest = K8s.build_job_manifest(ctx.task, "sykli-build-1234", ctx.state, opts)

      pod_spec = manifest["spec"]["template"]["spec"]
      main_container = Enum.find(pod_spec["containers"], &(&1["name"] == "task"))
      mounts = main_container["volumeMounts"] || []

      workspace_mount = Enum.find(mounts, &(&1["name"] == "workspace"))
      assert workspace_mount != nil
      assert workspace_mount["mountPath"] == "/workspace"
    end

    test "sets workingDir to /workspace when git_context provided", ctx do
      # Task without explicit workdir
      task = %{ctx.task | workdir: nil}
      opts = [git_context: ctx.git_ctx]

      manifest = K8s.build_job_manifest(task, "sykli-build-1234", ctx.state, opts)

      pod_spec = manifest["spec"]["template"]["spec"]
      main_container = Enum.find(pod_spec["containers"], &(&1["name"] == "task"))

      assert main_container["workingDir"] == "/workspace"
    end

    test "no init container when git_context not provided", ctx do
      opts = []

      manifest = K8s.build_job_manifest(ctx.task, "sykli-build-1234", ctx.state, opts)

      pod_spec = manifest["spec"]["template"]["spec"]
      init_containers = pod_spec["initContainers"]

      # Should have no init containers
      assert init_containers == nil or init_containers == []
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # GIT CLONE WITH SSH AUTH
  # ─────────────────────────────────────────────────────────────────────────────

  describe "build_job_manifest/4 with SSH auth" do
    setup do
      task = %Sykli.Graph.Task{
        name: "build",
        command: "cargo build",
        container: "rust:latest",
        k8s: %K8sOptions{}
      }

      state = %K8s{
        namespace: "sykli-test",
        auth_config: %{},
        artifact_pvc: "sykli-artifacts",
        in_cluster: false
      }

      git_ctx = %{
        url: "git@github.com:org/private-repo.git",
        branch: "main",
        sha: "abc123",
        dirty: false
      }

      %{task: task, state: state, git_ctx: git_ctx}
    end

    test "includes SSH key env when git_ssh_secret provided", ctx do
      opts = [git_context: ctx.git_ctx, git_ssh_secret: "deploy-key"]

      manifest = K8s.build_job_manifest(ctx.task, "sykli-build-1234", ctx.state, opts)

      pod_spec = manifest["spec"]["template"]["spec"]
      init_containers = pod_spec["initContainers"] || []
      git_clone = Enum.find(init_containers, &(&1["name"] == "git-clone"))

      env = git_clone["env"] || []
      ssh_key_env = Enum.find(env, &(&1["name"] == "GIT_SSH_KEY"))

      assert ssh_key_env != nil
      assert ssh_key_env["valueFrom"]["secretKeyRef"]["name"] == "deploy-key"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # GIT CLONE WITH TOKEN AUTH
  # ─────────────────────────────────────────────────────────────────────────────

  describe "build_job_manifest/4 with token auth" do
    setup do
      task = %Sykli.Graph.Task{
        name: "build",
        command: "cargo build",
        container: "rust:latest",
        k8s: %K8sOptions{}
      }

      state = %K8s{
        namespace: "sykli-test",
        auth_config: %{},
        artifact_pvc: "sykli-artifacts",
        in_cluster: false
      }

      git_ctx = %{
        url: "https://github.com/org/private-repo.git",
        branch: "main",
        sha: "abc123",
        dirty: false
      }

      %{task: task, state: state, git_ctx: git_ctx}
    end

    test "includes token env and embeds in URL when git_token_secret provided", ctx do
      opts = [git_context: ctx.git_ctx, git_token_secret: "github-token"]

      manifest = K8s.build_job_manifest(ctx.task, "sykli-build-1234", ctx.state, opts)

      pod_spec = manifest["spec"]["template"]["spec"]
      init_containers = pod_spec["initContainers"] || []
      git_clone = Enum.find(init_containers, &(&1["name"] == "git-clone"))

      # Check env
      env = git_clone["env"] || []
      token_env = Enum.find(env, &(&1["name"] == "GIT_TOKEN"))
      assert token_env != nil
      assert token_env["valueFrom"]["secretKeyRef"]["name"] == "github-token"

      # Check URL includes token variable
      command_str = Enum.at(git_clone["command"], 2)
      assert String.contains?(command_str, "https://${GIT_TOKEN}@github.com")
    end
  end
end
