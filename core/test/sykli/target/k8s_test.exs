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

      # Command should include clone and checkout (values are now quoted)
      command_str = Enum.at(git_clone["command"], 2)
      assert String.contains?(command_str, "git clone")
      assert String.contains?(command_str, "'https://github.com/org/repo.git'")
      assert String.contains?(command_str, "git checkout 'abc123def456789'")
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
        sha: "abc123def456789",
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
        sha: "abc123def456789",
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

  # ─────────────────────────────────────────────────────────────────────────────
  # RESOLVE SECRET - K8s API + ENV FALLBACK
  # ─────────────────────────────────────────────────────────────────────────────

  describe "resolve_secret/2" do
    setup do
      auth_config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "test-token"},
        ca_cert: nil,
        namespace: "default"
      }

      state = %K8s{
        namespace: "sykli-test",
        auth_config: auth_config,
        artifact_pvc: "sykli-artifacts",
        in_cluster: true
      }

      %{state: state, auth_config: auth_config}
    end

    test "reads secret from K8s API when available", ctx do
      # Mock HTTP client - secret with base64-encoded value
      # "my-secret-value" base64 encoded is "bXktc2VjcmV0LXZhbHVl"
      mock_http = fn :get, url, _headers, _body, _opts ->
        assert String.contains?(url, "/api/v1/namespaces/sykli-test/secrets/my-secret")

        {:ok,
         {{~c"HTTP/1.1", 200, ~c"OK"}, [],
          Jason.encode!(%{
            "data" => %{
              "value" => Base.encode64("my-secret-value")
            }
          })}}
      end

      result = K8s.resolve_secret("my-secret", ctx.state, http_client: mock_http)
      assert {:ok, "my-secret-value"} = result
    end

    test "reads specific key from secret when name contains slash", ctx do
      mock_http = fn :get, url, _headers, _body, _opts ->
        assert String.contains?(url, "/api/v1/namespaces/sykli-test/secrets/credentials")

        {:ok,
         {{~c"HTTP/1.1", 200, ~c"OK"}, [],
          Jason.encode!(%{
            "data" => %{
              "api-key" => Base.encode64("api-key-123"),
              "username" => Base.encode64("admin")
            }
          })}}
      end

      result = K8s.resolve_secret("credentials/api-key", ctx.state, http_client: mock_http)
      assert {:ok, "api-key-123"} = result
    end

    test "falls back to env var when K8s secret not found", ctx do
      mock_http = fn :get, _url, _headers, _body, _opts ->
        {:ok,
         {{~c"HTTP/1.1", 404, ~c"Not Found"}, [],
          Jason.encode!(%{"message" => "secrets \"my-secret\" not found"})}}
      end

      System.put_env("MY_SECRET", "from-env")

      result = K8s.resolve_secret("MY_SECRET", ctx.state, http_client: mock_http)
      assert {:ok, "from-env"} = result

      System.delete_env("MY_SECRET")
    end

    test "returns error when secret not found and no env fallback", ctx do
      mock_http = fn :get, _url, _headers, _body, _opts ->
        {:ok,
         {{~c"HTTP/1.1", 404, ~c"Not Found"}, [],
          Jason.encode!(%{"message" => "secrets \"no-exist\" not found"})}}
      end

      System.delete_env("no-exist")

      result = K8s.resolve_secret("no-exist", ctx.state, http_client: mock_http)
      assert {:error, :not_found} = result
    end

    test "falls back to env var on K8s API connection error", ctx do
      mock_http = fn :get, _url, _headers, _body, _opts ->
        {:error, :econnrefused}
      end

      System.put_env("MY_SECRET", "fallback-value")

      result = K8s.resolve_secret("MY_SECRET", ctx.state, http_client: mock_http)
      assert {:ok, "fallback-value"} = result

      System.delete_env("MY_SECRET")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CREATE VOLUME - PVC CREATION
  # ─────────────────────────────────────────────────────────────────────────────

  describe "create_volume/3" do
    setup do
      auth_config = %{
        api_url: "https://kubernetes.default.svc",
        auth: {:bearer, "test-token"},
        ca_cert: nil,
        namespace: "default"
      }

      state = %K8s{
        namespace: "sykli-test",
        auth_config: auth_config,
        artifact_pvc: "sykli-artifacts",
        in_cluster: true
      }

      %{state: state}
    end

    test "creates PVC when it doesn't exist", ctx do
      mock_http = fn
        :get, url, _headers, _body, _opts ->
          assert String.contains?(url, "/persistentvolumeclaims/sykli-cache-build-cache")
          {:ok, {{~c"HTTP/1.1", 404, ~c"Not Found"}, [], "{}"}}

        :post, url, _headers, body, _opts ->
          assert String.contains?(url, "/persistentvolumeclaims")
          pvc = Jason.decode!(body)
          assert pvc["metadata"]["name"] == "sykli-cache-build-cache"
          assert pvc["spec"]["resources"]["requests"]["storage"] == "2Gi"
          {:ok, {{~c"HTTP/1.1", 201, ~c"Created"}, [], Jason.encode!(pvc)}}
      end

      opts = %{size: "2Gi", type: :cache}
      result = K8s.create_volume("build-cache", opts, ctx.state, http_client: mock_http)

      assert {:ok, volume} = result
      assert volume.id == "sykli-cache-build-cache"
      assert volume.reference == "pvc:sykli-cache-build-cache"
    end

    test "returns existing PVC without creating", ctx do
      mock_http = fn :get, url, _headers, _body, _opts ->
        assert String.contains?(url, "/persistentvolumeclaims/sykli-cache-my-cache")

        {:ok,
         {{~c"HTTP/1.1", 200, ~c"OK"}, [],
          Jason.encode!(%{
            "metadata" => %{"name" => "sykli-cache-my-cache"},
            "spec" => %{"resources" => %{"requests" => %{"storage" => "1Gi"}}}
          })}}
      end

      opts = %{size: "1Gi", type: :cache}
      result = K8s.create_volume("my-cache", opts, ctx.state, http_client: mock_http)

      assert {:ok, volume} = result
      assert volume.id == "sykli-cache-my-cache"
    end

    test "uses directory type for non-cache volumes", ctx do
      mock_http = fn
        :get, url, _headers, _body, _opts ->
          assert String.contains?(url, "/persistentvolumeclaims/sykli-dir-workspace")
          {:ok, {{~c"HTTP/1.1", 404, ~c"Not Found"}, [], "{}"}}

        :post, _url, _headers, body, _opts ->
          pvc = Jason.decode!(body)
          assert pvc["metadata"]["name"] == "sykli-dir-workspace"
          {:ok, {{~c"HTTP/1.1", 201, ~c"Created"}, [], Jason.encode!(pvc)}}
      end

      opts = %{size: "5Gi", type: :directory}
      result = K8s.create_volume("workspace", opts, ctx.state, http_client: mock_http)

      assert {:ok, volume} = result
      assert volume.id == "sykli-dir-workspace"
    end

    test "returns error when PVC creation fails", ctx do
      mock_http = fn
        :get, _url, _headers, _body, _opts ->
          {:ok, {{~c"HTTP/1.1", 404, ~c"Not Found"}, [], "{}"}}

        :post, _url, _headers, _body, _opts ->
          {:ok,
           {{~c"HTTP/1.1", 403, ~c"Forbidden"}, [],
            Jason.encode!(%{"message" => "PVC creation not allowed"})}}
      end

      opts = %{size: "1Gi", type: :cache}
      result = K8s.create_volume("forbidden", opts, ctx.state, http_client: mock_http)

      assert {:error, {:pvc_creation_failed, _}} = result
    end

    test "uses custom storage class when provided", ctx do
      mock_http = fn
        :get, _url, _headers, _body, _opts ->
          {:ok, {{~c"HTTP/1.1", 404, ~c"Not Found"}, [], "{}"}}

        :post, _url, _headers, body, _opts ->
          pvc = Jason.decode!(body)
          assert pvc["spec"]["storageClassName"] == "fast-ssd"
          {:ok, {{~c"HTTP/1.1", 201, ~c"Created"}, [], Jason.encode!(pvc)}}
      end

      opts = %{size: "10Gi", type: :cache, storage_class: "fast-ssd"}
      result = K8s.create_volume("fast-cache", opts, ctx.state, http_client: mock_http)

      assert {:ok, _} = result
    end
  end
end
