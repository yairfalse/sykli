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
        {:error,
         "OIDC not available: not running in a supported CI environment (GitHub Actions, GitLab CI). Use SecretFrom(FromEnv(...)) for local development."}
    end
  end

  defp acquire_github_token(audience) do
    url = System.get_env("ACTIONS_ID_TOKEN_REQUEST_URL")
    token = System.get_env("ACTIONS_ID_TOKEN_REQUEST_TOKEN")

    # Validate both env vars are present
    cond do
      is_nil(url) or url == "" ->
        {:error, "ACTIONS_ID_TOKEN_REQUEST_URL is not set"}

      is_nil(token) or token == "" ->
        {:error,
         "ACTIONS_ID_TOKEN_REQUEST_TOKEN is not set — ensure the job has `permissions: id-token: write`"}

      true ->
        do_acquire_github_token(url, token, audience)
    end
  end

  defp do_acquire_github_token(url, token, audience) do
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
    with :ok <- require_fields(binding, [:role_arn], "AWS") do
      exchange_aws(binding, id_token)
    end
  end

  defp exchange_for_credentials(%CredentialBinding{provider: :gcp} = binding, id_token) do
    with :ok <- require_fields(binding, [:project_number, :pool_id, :provider_id], "GCP") do
      exchange_gcp(binding, id_token)
    end
  end

  defp exchange_for_credentials(%CredentialBinding{provider: :azure} = binding, id_token) do
    with :ok <- require_fields(binding, [:tenant_id, :client_id], "Azure") do
      exchange_azure(binding, id_token)
    end
  end

  defp require_fields(binding, fields, provider) do
    missing =
      fields
      |> Enum.filter(fn f ->
        val = Map.get(binding, f)
        is_nil(val) or val == ""
      end)

    if missing == [] do
      :ok
    else
      names = Enum.map_join(missing, ", ", &Atom.to_string/1)
      {:error, "#{provider} OIDC requires: #{names}"}
    end
  end

  defp exchange_aws(%CredentialBinding{role_arn: role_arn, duration: duration}, id_token) do
    :inets.start()
    :ssl.start()

    params =
      URI.encode_query(%{
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
      {:ok,
       %{
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

  defp exchange_gcp(
         %CredentialBinding{project_number: pn, pool_id: pool, provider_id: prov},
         id_token
       ) do
    :inets.start()
    :ssl.start()

    # Step 1: Exchange for STS token
    audience =
      "//iam.googleapis.com/projects/#{pn}/locations/global/workloadIdentityPools/#{pool}/providers/#{prov}"

    body =
      Jason.encode!(%{
        "audience" => audience,
        "grantType" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "requestedTokenType" => "urn:ietf:params:oauth:token-type:access_token",
        "scope" => "https://www.googleapis.com/auth/cloud-platform",
        "subjectTokenType" => "urn:ietf:params:oauth:token-type:jwt",
        "subjectToken" => id_token
      })

    headers = [{~c"Content-Type", ~c"application/json"}]

    case :httpc.request(
           :post,
           {~c"https://sts.googleapis.com/v1/token", headers, ~c"application/json",
            String.to_charlist(body)},
           [{:timeout, 30_000}],
           []
         ) do
      {:ok, {{_, 200, _}, _, resp_body}} ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, %{"access_token" => access_token}} ->
            # Write token to a secure temp file first
            token_file = secure_write_temp("sykli-gcp-token", ".jwt", id_token)

            # Write credentials file referencing the token file
            creds =
              Jason.encode!(%{
                "type" => "external_account",
                "audience" => audience,
                "subject_token_type" => "urn:ietf:params:oauth:token-type:jwt",
                "token_url" => "https://sts.googleapis.com/v1/token",
                "credential_source" => %{"file" => token_file}
              })

            creds_file = secure_write_temp("sykli-gcp-creds", ".json", creds)

            {:ok,
             %{
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
    token_file = secure_write_temp("sykli-azure-token", "", id_token)

    {:ok,
     %{
       "AZURE_FEDERATED_TOKEN_FILE" => token_file,
       "AZURE_CLIENT_ID" => client,
       "AZURE_TENANT_ID" => tenant
     }}
  end

  @doc """
  Cleans up any temp files created during OIDC exchange.
  Call this after task completion (even on failure).
  """
  def cleanup_temp_files do
    case Process.get(:sykli_oidc_temp_files) do
      nil ->
        :ok

      files ->
        Enum.each(files, fn path ->
          File.rm(path)
        end)

        Process.delete(:sykli_oidc_temp_files)
        :ok
    end
  end

  # Create a temp file securely with exclusive mode and restrictive permissions.
  # Tracks the file path in process dictionary for cleanup.
  defp secure_write_temp(prefix, extension, content) do
    path = secure_temp_path(prefix, extension)

    case File.open(path, [:write, :exclusive]) do
      {:ok, fd} ->
        try do
          IO.binwrite(fd, content)
        after
          File.close(fd)
        end

        File.chmod!(path, 0o600)
        track_temp_file(path)
        path

      {:error, :eexist} ->
        # Extremely unlikely collision, retry with new random
        secure_write_temp(prefix, extension, content)
    end
  end

  defp secure_temp_path(prefix, extension) do
    random = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "#{prefix}-#{random}#{extension}")
  end

  defp track_temp_file(path) do
    existing = Process.get(:sykli_oidc_temp_files, [])
    Process.put(:sykli_oidc_temp_files, [path | existing])
  end
end
