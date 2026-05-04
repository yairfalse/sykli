defmodule Sykli.GitHub.Checks.Real do
  @moduledoc "GitHub Checks API client."

  @behaviour Sykli.GitHub.Checks.Behaviour

  require Logger

  @api_url "https://api.github.com"

  @impl true
  def create_suite(%{repo: repo, head_sha: head_sha}, token, opts \\ []) do
    request(
      :post,
      "/repos/#{repo}/check-suites",
      token,
      %{head_sha: head_sha},
      opts,
      "github.checks.write_failed"
    )
  end

  @impl true
  def create_run(%{repo: repo, head_sha: head_sha}, token, opts \\ []) do
    name = Keyword.get(opts, :name, "sykli")
    status = Keyword.get(opts, :status, "queued")

    request(
      :post,
      "/repos/#{repo}/check-runs",
      token,
      %{name: name, head_sha: head_sha, status: status},
      opts,
      "github.checks.write_failed"
    )
  end

  @impl true
  def update_run(%{repo: repo, check_run_id: check_run_id}, token, attrs, opts \\ []) do
    request(
      :patch,
      "/repos/#{repo}/check-runs/#{check_run_id}",
      token,
      attrs,
      opts,
      "github.checks.write_failed"
    )
  end

  defp request(method, path, token, payload, opts, error_code) do
    client =
      Keyword.get(
        opts,
        :http_client,
        Application.get_env(:sykli, :github_http_client, Sykli.GitHub.HTTPClient.Real)
      )

    api_url = Keyword.get(opts, :api_url, Application.get_env(:sykli, :github_api_url, @api_url))
    url = api_url <> path
    body = Jason.encode!(payload)

    headers = [
      {~c"Authorization", String.to_charlist("Bearer #{token}")},
      {~c"Accept", ~c"application/vnd.github+json"},
      {~c"X-GitHub-Api-Version", ~c"2022-11-28"},
      {~c"User-Agent", ~c"sykli/0.6"},
      {~c"Content-Type", ~c"application/json"}
    ]

    case client.request(method, url, headers, body) do
      {:ok, code, response} when code in 200..299 ->
        decode_response(response)

      {:ok, code, response} ->
        Logger.warning("[GitHub Checks] request failed", code: code, path: path)
        {:error, github_error(error_code, "GitHub Checks API request failed", {code, response})}

      {:error, reason} ->
        {:error, github_error(error_code, "GitHub Checks API request failed", reason)}
    end
  end

  defp decode_response(""), do: {:ok, %{}}

  defp decode_response(body) do
    case Jason.decode(body) do
      {:ok, data} ->
        {:ok, data}

      {:error, reason} ->
        {:error,
         github_error(
           "github.checks.bad_response",
           "GitHub Checks API response was invalid",
           reason
         )}
    end
  end

  defp github_error(code, message, cause) do
    %Sykli.Error{
      code: code,
      type: :runtime,
      message: message,
      step: :run,
      cause: cause,
      hints: []
    }
  end
end
