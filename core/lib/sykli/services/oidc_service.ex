defmodule Sykli.Services.OIDCService do
  @moduledoc """
  OIDC token exchange for cloud provider credentials.

  Acquires identity tokens from CI providers (GitHub, GitLab) and
  exchanges them for short-lived cloud credentials.
  """

  alias Sykli.Graph.Task.CredentialBinding

  @doc """
  Exchange OIDC token for cloud credentials.
  Returns {:ok, env_map} or {:error, reason}.
  """
  @spec exchange(Sykli.Graph.Task.t(), map()) :: {:ok, map()} | {:error, term()}
  def exchange(%{oidc: nil}, _state), do: {:ok, %{}}

  def exchange(%{oidc: %CredentialBinding{} = binding}, _state) do
    with {:ok, id_token} <- acquire_identity_token(binding) do
      exchange_for_credentials(binding, id_token)
    end
  end

  # Acquire identity token from CI provider
  defp acquire_identity_token(%CredentialBinding{audience: audience}) do
    cond do
      # GitHub Actions OIDC
      System.get_env("ACTIONS_ID_TOKEN_REQUEST_URL") != nil ->
        acquire_github_token(audience)

      # GitLab CI JWT
      System.get_env("CI_JOB_JWT_V2") != nil ->
        {:ok, System.get_env("CI_JOB_JWT_V2")}

      # Local dev - no OIDC available
      true ->
        {:error, "OIDC not available: not running in a supported CI environment (GitHub Actions, GitLab CI). Use SecretFrom(FromEnv(...)) for local development."}
    end
  end

  defp acquire_github_token(audience) do
    url = System.get_env("ACTIONS_ID_TOKEN_REQUEST_URL")
    token = System.get_env("ACTIONS_ID_TOKEN_REQUEST_TOKEN")

    url = if audience, do: "#{url}&audience=#{URI.encode_www_form(audience)}", else: url

    # Use :httpc for HTTP request (available in OTP)
    :inets.start()
    :ssl.start()

    headers = [
      {~c"Authorization", ~c"bearer #{token}"},
      {~c"Accept", ~c"application/json"}
    ]

    case :httpc.request(:get, {String.to_charlist(url), headers}, [{:timeout, 10_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, %{"value" => id_token}} -> {:ok, id_token}
          _ -> {:error, "failed to parse GitHub OIDC response"}
        end
      {:ok, {{_, status, _}, _, body}} ->
        {:error, "GitHub OIDC request failed (HTTP #{status}): #{to_string(body)}"}
      {:error, reason} ->
        {:error, "GitHub OIDC request failed: #{inspect(reason)}"}
    end
  end

  # Exchange identity token for cloud credentials
  defp exchange_for_credentials(%CredentialBinding{provider: :aws} = binding, id_token) do
    exchange_aws(binding, id_token)
  end

  defp exchange_for_credentials(%CredentialBinding{provider: :gcp} = binding, id_token) do
    exchange_gcp(binding, id_token)
  end

  defp exchange_for_credentials(%CredentialBinding{provider: :azure} = binding, id_token) do
    exchange_azure(binding, id_token)
  end

  defp exchange_aws(%CredentialBinding{role_arn: role_arn, duration: duration}, id_token) do
    :inets.start()
    :ssl.start()

    params = URI.encode_query(%{
      "Action" => "AssumeRoleWithWebIdentity",
      "Version" => "2011-06-15",
      "RoleArn" => role_arn,
      "RoleSessionName" => "sykli-#{System.os_time(:second)}",
      "WebIdentityToken" => id_token,
      "DurationSeconds" => to_string(duration)
    })

    url = ~c"https://sts.amazonaws.com/?#{params}"

    case :httpc.request(:get, {url, []}, [{:timeout, 30_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        parse_aws_response(to_string(body))
      {:ok, {{_, status, _}, _, body}} ->
        {:error, "AWS STS request failed (HTTP #{status}): #{to_string(body)}"}
      {:error, reason} ->
        {:error, "AWS STS request failed: #{inspect(reason)}"}
    end
  end

  defp parse_aws_response(xml) do
    # Simple XML parsing for STS response
    access_key = extract_xml_value(xml, "AccessKeyId")
    secret_key = extract_xml_value(xml, "SecretAccessKey")
    session_token = extract_xml_value(xml, "SessionToken")

    if access_key && secret_key && session_token do
      {:ok, %{
        "AWS_ACCESS_KEY_ID" => access_key,
        "AWS_SECRET_ACCESS_KEY" => secret_key,
        "AWS_SESSION_TOKEN" => session_token
      }}
    else
      {:error, "failed to parse AWS STS response"}
    end
  end

  defp extract_xml_value(xml, tag) do
    case Regex.run(~r/<#{tag}>([^<]+)<\/#{tag}>/, xml) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp exchange_gcp(%CredentialBinding{project_number: pn, pool_id: pool, provider_id: prov}, id_token) do
    :inets.start()
    :ssl.start()

    # Step 1: Exchange for STS token
    audience = "//iam.googleapis.com/projects/#{pn}/locations/global/workloadIdentityPools/#{pool}/providers/#{prov}"

    body = Jason.encode!(%{
      "audience" => audience,
      "grantType" => "urn:ietf:params:oauth:grant-type:token-exchange",
      "requestedTokenType" => "urn:ietf:params:oauth:token-type:access_token",
      "scope" => "https://www.googleapis.com/auth/cloud-platform",
      "subjectTokenType" => "urn:ietf:params:oauth:token-type:jwt",
      "subjectToken" => id_token
    })

    headers = [{~c"Content-Type", ~c"application/json"}]

    case :httpc.request(:post, {~c"https://sts.googleapis.com/v1/token", headers, ~c"application/json", String.to_charlist(body)}, [{:timeout, 30_000}], []) do
      {:ok, {{_, 200, _}, _, resp_body}} ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, %{"access_token" => access_token}} ->
            # Write credentials to temp file
            creds_file = Path.join(System.tmp_dir!(), "sykli-gcp-creds-#{System.os_time(:second)}.json")
            creds = Jason.encode!(%{
              "type" => "external_account",
              "audience" => audience,
              "token_url" => "https://sts.googleapis.com/v1/token",
              "credential_source" => %{"file" => ""},
              "service_account_impersonation_url" => ""
            })
            File.write!(creds_file, creds)

            {:ok, %{
              "GOOGLE_APPLICATION_CREDENTIALS" => creds_file,
              "CLOUDSDK_AUTH_ACCESS_TOKEN" => access_token
            }}
          _ ->
            {:error, "failed to parse GCP STS response"}
        end
      {:ok, {{_, status, _}, _, resp_body}} ->
        {:error, "GCP STS request failed (HTTP #{status}): #{to_string(resp_body)}"}
      {:error, reason} ->
        {:error, "GCP STS request failed: #{inspect(reason)}"}
    end
  end

  defp exchange_azure(%CredentialBinding{tenant_id: tenant, client_id: client}, id_token) do
    # Azure uses federated token file approach
    token_file = Path.join(System.tmp_dir!(), "sykli-azure-token-#{System.os_time(:second)}")
    File.write!(token_file, id_token)

    {:ok, %{
      "AZURE_FEDERATED_TOKEN_FILE" => token_file,
      "AZURE_CLIENT_ID" => client,
      "AZURE_TENANT_ID" => tenant
    }}
  end
end
