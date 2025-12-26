defmodule Sykli.K8s.Auth do
  @moduledoc """
  Kubernetes authentication detection and configuration.

  Auto-detects the authentication environment:
  1. In-cluster: Uses service account token from pod filesystem
  2. Kubeconfig: Parses ~/.kube/config or $KUBECONFIG

  Supported auth methods:
  - Bearer token (in-cluster or kubeconfig token field)
  - Client certificate (kubeconfig client-certificate-data)

  Not supported in v1:
  - Exec-based auth (EKS, GKE)
  - Auth-provider (OIDC)
  """

  @default_sa_path "/var/run/secrets/kubernetes.io/serviceaccount"
  @default_kubeconfig_paths [
    Path.expand("~/.kube/config")
  ]

  @type auth_method :: {:bearer, String.t()} | {:cert, {String.t(), String.t()}}

  @type config :: %{
          api_url: String.t(),
          auth: auth_method(),
          ca_cert: String.t() | nil,
          namespace: String.t() | nil
        }

  @doc """
  Auto-detects Kubernetes authentication from environment.

  Checks in order:
  1. In-cluster service account (if running in K8s)
  2. Kubeconfig file ($KUBECONFIG or ~/.kube/config)

  ## Options
    * `:in_cluster_path` - Override service account path (for testing)
    * `:kubeconfig_paths` - Override kubeconfig search paths
    * `:context` - Use specific context instead of current-context

  ## Returns
    * `{:ok, config}` - Authentication config map
    * `{:error, :no_auth}` - No authentication found
  """
  @spec detect(keyword()) :: {:ok, config()} | {:error, :no_auth}
  def detect(opts \\ []) do
    sa_path = Keyword.get(opts, :in_cluster_path, @default_sa_path)

    if in_cluster?(sa_path) do
      from_service_account(sa_path)
    else
      kubeconfig_paths = Keyword.get(opts, :kubeconfig_paths, default_kubeconfig_paths())
      context = Keyword.get(opts, :context)

      case find_kubeconfig(kubeconfig_paths) do
        {:ok, path} -> from_kubeconfig(path, context: context)
        :error -> {:error, :no_auth}
      end
    end
  end

  @doc """
  Checks if running inside a Kubernetes cluster.

  Returns true if the service account token file exists.
  """
  @spec in_cluster?(String.t()) :: boolean()
  def in_cluster?(sa_path \\ @default_sa_path) do
    File.exists?(Path.join(sa_path, "token"))
  end

  @doc """
  Reads authentication from in-cluster service account.

  Expects the standard K8s service account mount at:
  - /var/run/secrets/kubernetes.io/serviceaccount/token
  - /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  - /var/run/secrets/kubernetes.io/serviceaccount/namespace
  """
  @spec from_service_account(String.t()) :: {:ok, config()} | {:error, :token_not_found}
  def from_service_account(sa_path) do
    token_path = Path.join(sa_path, "token")
    ca_path = Path.join(sa_path, "ca.crt")
    namespace_path = Path.join(sa_path, "namespace")

    with {:ok, token} <- read_file(token_path, :token_not_found),
         ca_cert <- read_optional_file(ca_path),
         namespace <- read_optional_file(namespace_path) do
      {:ok,
       %{
         api_url: "https://kubernetes.default.svc",
         auth: {:bearer, String.trim(token)},
         ca_cert: ca_cert && String.trim(ca_cert),
         namespace: namespace && String.trim(namespace)
       }}
    end
  end

  @doc """
  Reads authentication from a kubeconfig file.

  ## Options
    * `:context` - Use specific context instead of current-context

  ## Returns
    * `{:ok, config}` - Parsed configuration
    * `{:error, :kubeconfig_not_found}` - File doesn't exist
    * `{:error, {:context_not_found, name}}` - Context not in file
    * `{:error, :exec_auth_not_supported}` - Exec auth method used
  """
  @spec from_kubeconfig(String.t(), keyword()) ::
          {:ok, config()}
          | {:error, :kubeconfig_not_found}
          | {:error, {:context_not_found, String.t()}}
          | {:error, :exec_auth_not_supported}
  def from_kubeconfig(path, opts \\ []) do
    with {:ok, content} <- read_file(path, :kubeconfig_not_found),
         {:ok, kubeconfig} <- parse_yaml(content),
         context_name <- Keyword.get(opts, :context) || kubeconfig["current-context"],
         {:ok, context} <- find_context(kubeconfig, context_name),
         {:ok, cluster} <- find_cluster(kubeconfig, context["context"]["cluster"]),
         {:ok, user} <- find_user(kubeconfig, context["context"]["user"]),
         {:ok, auth} <- extract_auth(user) do
      namespace = get_in(context, ["context", "namespace"])
      ca_cert = extract_ca_cert(cluster)

      {:ok,
       %{
         api_url: cluster["cluster"]["server"],
         auth: auth,
         ca_cert: ca_cert,
         namespace: namespace
       }}
    end
  end

  # Private helpers

  defp default_kubeconfig_paths do
    case System.get_env("KUBECONFIG") do
      nil -> @default_kubeconfig_paths
      path -> [path | @default_kubeconfig_paths]
    end
  end

  defp find_kubeconfig([]), do: :error

  defp find_kubeconfig([path | rest]) do
    if File.exists?(path) do
      {:ok, path}
    else
      find_kubeconfig(rest)
    end
  end

  defp read_file(path, error_atom) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, error_atom}
    end
  end

  defp read_optional_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp parse_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, :invalid_kubeconfig}
    end
  end

  defp find_context(kubeconfig, name) do
    contexts = kubeconfig["contexts"] || []

    case Enum.find(contexts, fn c -> c["name"] == name end) do
      nil -> {:error, {:context_not_found, name}}
      context -> {:ok, context}
    end
  end

  defp find_cluster(kubeconfig, name) do
    clusters = kubeconfig["clusters"] || []

    case Enum.find(clusters, fn c -> c["name"] == name end) do
      nil -> {:error, {:cluster_not_found, name}}
      cluster -> {:ok, cluster}
    end
  end

  defp find_user(kubeconfig, name) do
    users = kubeconfig["users"] || []

    case Enum.find(users, fn u -> u["name"] == name end) do
      nil -> {:error, {:user_not_found, name}}
      user -> {:ok, user}
    end
  end

  defp extract_auth(%{"user" => user}) do
    cond do
      # Exec auth - not supported
      Map.has_key?(user, "exec") ->
        {:error, :exec_auth_not_supported}

      # Auth provider - not supported
      Map.has_key?(user, "auth-provider") ->
        {:error, :auth_provider_not_supported}

      # Bearer token
      Map.has_key?(user, "token") ->
        {:ok, {:bearer, user["token"]}}

      # Client certificate
      Map.has_key?(user, "client-certificate-data") and Map.has_key?(user, "client-key-data") ->
        cert = Base.decode64!(user["client-certificate-data"])
        key = Base.decode64!(user["client-key-data"])
        {:ok, {:cert, {cert, key}}}

      # No auth method found
      true ->
        {:error, :no_auth_method}
    end
  end

  defp extract_ca_cert(%{"cluster" => cluster}) do
    cond do
      Map.has_key?(cluster, "certificate-authority-data") ->
        Base.decode64!(cluster["certificate-authority-data"])

      Map.has_key?(cluster, "certificate-authority") ->
        case File.read(cluster["certificate-authority"]) do
          {:ok, content} -> content
          {:error, _} -> nil
        end

      true ->
        nil
    end
  end
end
