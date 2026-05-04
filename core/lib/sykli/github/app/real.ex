defmodule Sykli.GitHub.App.Real do
  @moduledoc "GitHub App JWT signing and installation token acquisition."

  @behaviour Sykli.GitHub.App.Behaviour

  require Logger

  alias Sykli.GitHub.App.Cache

  @api_url "https://api.github.com"

  @impl true
  def installation_token(installation_id, opts \\ []) do
    clock =
      Keyword.get(
        opts,
        :clock,
        Application.get_env(:sykli, :github_clock, Sykli.GitHub.Clock.Real)
      )

    now = clock.now_seconds()

    case Cache.get(installation_id, now) do
      {:ok, token, expires_at} ->
        {:ok, token, expires_at}

      :miss ->
        fetch_installation_token(installation_id, now, opts)
    end
  end

  def sign_jwt(app_id, private_key_pem, now_seconds) do
    claims = %{
      "iat" => now_seconds - 60,
      "exp" => now_seconds + 540,
      "iss" => to_string(app_id)
    }

    signer = Joken.Signer.create("RS256", %{"pem" => private_key_pem})

    case Joken.encode_and_sign(claims, signer) do
      {:ok, token, _claims} ->
        {:ok, token}

      {:error, reason} ->
        {:error, github_error("github.app.jwt_failed", "failed to sign GitHub App JWT", reason)}
    end
  rescue
    e -> {:error, github_error("github.app.jwt_failed", "failed to sign GitHub App JWT", e)}
  end

  defp fetch_installation_token(installation_id, now, opts) do
    with {:ok, app_id} <- app_id(opts),
         {:ok, pem} <- private_key(opts),
         {:ok, jwt} <- sign_jwt(app_id, pem, now),
         {:ok, token, expires_at} <- request_installation_token(installation_id, jwt, opts) do
      Cache.put(installation_id, token, expires_at)
      {:ok, token, expires_at}
    end
  end

  defp request_installation_token(installation_id, jwt, opts) do
    client =
      Keyword.get(
        opts,
        :http_client,
        Application.get_env(:sykli, :github_http_client, Sykli.GitHub.HTTPClient.Real)
      )

    api_url = Keyword.get(opts, :api_url, Application.get_env(:sykli, :github_api_url, @api_url))
    url = "#{api_url}/app/installations/#{installation_id}/access_tokens"

    headers = [
      {~c"Authorization", String.to_charlist("Bearer #{jwt}")},
      {~c"Accept", ~c"application/vnd.github+json"},
      {~c"X-GitHub-Api-Version", ~c"2022-11-28"},
      {~c"User-Agent", ~c"sykli/0.6"}
    ]

    case client.request(:post, url, headers, "{}") do
      {:ok, code, body} when code in 200..299 ->
        decode_token_response(body)

      {:ok, code, body} when code in [401, 403] ->
        Logger.warning("[GitHub App] installation token request failed",
          code: code,
          installation_id: installation_id
        )

        {:error,
         github_error(
           "github.app.unauthorized",
           "GitHub installation token request failed",
           {code, body}
         )}

      {:ok, code, body} when code in 500..599 ->
        Logger.warning("[GitHub App] installation token request failed",
          code: code,
          installation_id: installation_id
        )

        {:error,
         github_error(
           "github.app.upstream_error",
           "GitHub installation token service failed",
           {code, body}
         )}

      {:ok, code, body} ->
        Logger.warning("[GitHub App] installation token request returned an unexpected status",
          code: code,
          installation_id: installation_id
        )

        {:error,
         github_error(
           "github.app.bad_response",
           "GitHub installation token response was invalid",
           {code, body}
         )}

      {:error, reason} ->
        {:error,
         github_error(
           "github.app.transport_failed",
           "GitHub installation token request could not reach GitHub",
           reason
         )}
    end
  end

  defp decode_token_response(body) do
    with {:ok, data} <- Jason.decode(body),
         token when is_binary(token) <- data["token"],
         expires_at when is_binary(expires_at) <- data["expires_at"],
         {:ok, dt, _offset} <- DateTime.from_iso8601(expires_at) do
      {:ok, token, DateTime.to_unix(dt)}
    else
      reason ->
        {:error,
         github_error(
           "github.app.bad_response",
           "GitHub installation token response was invalid",
           reason
         )}
    end
  end

  defp app_id(opts) do
    case Keyword.get(opts, :app_id, System.get_env("SYKLI_GITHUB_APP_ID")) do
      nil ->
        {:error, github_error("github.app.missing_config", "SYKLI_GITHUB_APP_ID is required")}

      "" ->
        {:error, github_error("github.app.missing_config", "SYKLI_GITHUB_APP_ID is required")}

      id ->
        {:ok, id}
    end
  end

  defp private_key(opts) do
    case Keyword.get(opts, :private_key, System.get_env("SYKLI_GITHUB_APP_PRIVATE_KEY")) do
      nil ->
        {:error,
         github_error("github.app.missing_config", "SYKLI_GITHUB_APP_PRIVATE_KEY is required")}

      "" ->
        {:error,
         github_error("github.app.missing_config", "SYKLI_GITHUB_APP_PRIVATE_KEY is required")}

      value ->
        read_private_key(value)
    end
  end

  defp read_private_key(value) do
    cond do
      String.contains?(value, "BEGIN") ->
        {:ok, value}

      File.exists?(value) ->
        File.read(value)

      true ->
        {:error,
         github_error("github.app.private_key_not_found", "GitHub App private key was not found")}
    end
  end

  defp github_error(code, message, cause \\ nil) do
    %Sykli.Error{
      code: code,
      type: :runtime,
      message: message,
      step: :setup,
      cause: cause,
      hints: []
    }
  end
end
