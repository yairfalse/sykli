defmodule Sykli.K8s.AuthTest do
  use ExUnit.Case, async: true

  alias Sykli.K8s.Auth

  describe "detect/0" do
    test "returns error when no auth available" do
      # Clear any env vars that might interfere
      original_kubeconfig = System.get_env("KUBECONFIG")
      System.delete_env("KUBECONFIG")

      # Mock the file system checks to return false
      # In actual implementation, we'll need to make this testable
      result =
        Auth.detect(
          in_cluster_path: "/nonexistent/path",
          kubeconfig_paths: ["/nonexistent/kubeconfig"]
        )

      assert {:error, :no_auth} = result

      # Restore
      if original_kubeconfig, do: System.put_env("KUBECONFIG", original_kubeconfig)
    end
  end

  describe "from_service_account/1" do
    test "reads token and ca from service account path" do
      # Create temp files to simulate in-cluster
      tmp_dir = System.tmp_dir!()
      sa_path = Path.join(tmp_dir, "sa_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(sa_path)

      token = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test"
      ca_cert = "-----BEGIN CERTIFICATE-----\nMIIC...\n-----END CERTIFICATE-----"
      namespace = "test-namespace"

      File.write!(Path.join(sa_path, "token"), token)
      File.write!(Path.join(sa_path, "ca.crt"), ca_cert)
      File.write!(Path.join(sa_path, "namespace"), namespace)

      result = Auth.from_service_account(sa_path)

      assert {:ok, config} = result
      assert config.api_url == "https://kubernetes.default.svc"
      assert config.auth == {:bearer, token}
      assert config.ca_cert == ca_cert
      assert config.namespace == namespace

      # Cleanup
      File.rm_rf!(sa_path)
    end

    test "returns error when token file missing" do
      tmp_dir = System.tmp_dir!()
      sa_path = Path.join(tmp_dir, "sa_empty_#{:rand.uniform(100_000)}")
      File.mkdir_p!(sa_path)

      result = Auth.from_service_account(sa_path)

      assert {:error, :token_not_found} = result

      File.rm_rf!(sa_path)
    end
  end

  describe "from_kubeconfig/1" do
    test "parses kubeconfig with static token" do
      kubeconfig = """
      apiVersion: v1
      kind: Config
      current-context: test-context
      clusters:
      - name: test-cluster
        cluster:
          server: https://127.0.0.1:6443
          certificate-authority-data: #{Base.encode64("ca-cert-data")}
      contexts:
      - name: test-context
        context:
          cluster: test-cluster
          user: test-user
          namespace: default
      users:
      - name: test-user
        user:
          token: my-static-token
      """

      tmp_path = Path.join(System.tmp_dir!(), "kubeconfig_#{:rand.uniform(100_000)}")
      File.write!(tmp_path, kubeconfig)

      result = Auth.from_kubeconfig(tmp_path)

      assert {:ok, config} = result
      assert config.api_url == "https://127.0.0.1:6443"
      assert config.auth == {:bearer, "my-static-token"}
      assert config.ca_cert == "ca-cert-data"
      assert config.namespace == "default"

      File.rm!(tmp_path)
    end

    test "parses kubeconfig with client certificate" do
      kubeconfig = """
      apiVersion: v1
      kind: Config
      current-context: cert-context
      clusters:
      - name: cert-cluster
        cluster:
          server: https://10.0.0.1:6443
      contexts:
      - name: cert-context
        context:
          cluster: cert-cluster
          user: cert-user
      users:
      - name: cert-user
        user:
          client-certificate-data: #{Base.encode64("client-cert")}
          client-key-data: #{Base.encode64("client-key")}
      """

      tmp_path = Path.join(System.tmp_dir!(), "kubeconfig_cert_#{:rand.uniform(100_000)}")
      File.write!(tmp_path, kubeconfig)

      result = Auth.from_kubeconfig(tmp_path)

      assert {:ok, config} = result
      assert config.api_url == "https://10.0.0.1:6443"
      assert config.auth == {:cert, {"client-cert", "client-key"}}

      File.rm!(tmp_path)
    end

    test "uses specified context instead of current-context" do
      kubeconfig = """
      apiVersion: v1
      kind: Config
      current-context: default-context
      clusters:
      - name: prod-cluster
        cluster:
          server: https://prod.example.com:6443
      - name: dev-cluster
        cluster:
          server: https://dev.example.com:6443
      contexts:
      - name: default-context
        context:
          cluster: dev-cluster
          user: dev-user
      - name: prod-context
        context:
          cluster: prod-cluster
          user: prod-user
      users:
      - name: dev-user
        user:
          token: dev-token
      - name: prod-user
        user:
          token: prod-token
      """

      tmp_path = Path.join(System.tmp_dir!(), "kubeconfig_multi_#{:rand.uniform(100_000)}")
      File.write!(tmp_path, kubeconfig)

      result = Auth.from_kubeconfig(tmp_path, context: "prod-context")

      assert {:ok, config} = result
      assert config.api_url == "https://prod.example.com:6443"
      assert config.auth == {:bearer, "prod-token"}

      File.rm!(tmp_path)
    end

    test "returns error for exec auth (unsupported in v1)" do
      kubeconfig = """
      apiVersion: v1
      kind: Config
      current-context: eks-context
      clusters:
      - name: eks-cluster
        cluster:
          server: https://eks.amazonaws.com
      contexts:
      - name: eks-context
        context:
          cluster: eks-cluster
          user: eks-user
      users:
      - name: eks-user
        user:
          exec:
            command: aws
            args: ["eks", "get-token"]
      """

      tmp_path = Path.join(System.tmp_dir!(), "kubeconfig_exec_#{:rand.uniform(100_000)}")
      File.write!(tmp_path, kubeconfig)

      result = Auth.from_kubeconfig(tmp_path)

      assert {:error, :exec_auth_not_supported} = result

      File.rm!(tmp_path)
    end

    test "returns error when kubeconfig not found" do
      result = Auth.from_kubeconfig("/nonexistent/path/kubeconfig")

      assert {:error, :kubeconfig_not_found} = result
    end

    test "returns error when context not found" do
      kubeconfig = """
      apiVersion: v1
      kind: Config
      current-context: missing-context
      clusters: []
      contexts: []
      users: []
      """

      tmp_path = Path.join(System.tmp_dir!(), "kubeconfig_empty_#{:rand.uniform(100_000)}")
      File.write!(tmp_path, kubeconfig)

      result = Auth.from_kubeconfig(tmp_path)

      assert {:error, {:context_not_found, "missing-context"}} = result

      File.rm!(tmp_path)
    end
  end

  describe "in_cluster?/1" do
    test "returns true when service account files exist" do
      tmp_dir = System.tmp_dir!()
      sa_path = Path.join(tmp_dir, "sa_check_#{:rand.uniform(100_000)}")
      File.mkdir_p!(sa_path)
      File.write!(Path.join(sa_path, "token"), "token")

      assert Auth.in_cluster?(sa_path) == true

      File.rm_rf!(sa_path)
    end

    test "returns false when service account files missing" do
      assert Auth.in_cluster?("/nonexistent/path") == false
    end
  end
end
