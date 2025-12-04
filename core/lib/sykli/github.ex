defmodule Sykli.GitHub do
  @moduledoc """
  GitHub commit status integration.
  Posts per-task status to GitHub API.
  """

  @api_url "https://api.github.com"

  @doc """
  Check if GitHub integration is available (env vars set).
  """
  def enabled? do
    token() != nil and repo() != nil and sha() != nil
  end

  @doc """
  Update commit status for a task.
  State: "pending" | "success" | "failure" | "error"
  """
  def update_status(task_name, state, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "ci/sykli")
    context = "#{prefix}/#{task_name}"

    body = Jason.encode!(%{
      state: state,
      context: context,
      description: description_for(state, task_name)
    })

    url = "#{@api_url}/repos/#{repo()}/statuses/#{sha()}"

    case :httpc.request(
      :post,
      {String.to_charlist(url), headers(), ~c"application/json", body},
      [{:ssl, ssl_opts()}],
      []
    ) do
      {:ok, {{_, code, _}, _, _}} when code in 200..299 ->
        :ok

      {:ok, {{_, code, _}, _, response}} ->
        {:error, {:http_error, code, to_string(response)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ----- PRIVATE -----

  defp token, do: System.get_env("GITHUB_TOKEN")
  defp repo, do: System.get_env("GITHUB_REPOSITORY")
  defp sha, do: System.get_env("GITHUB_SHA")

  defp headers do
    [
      {~c"Authorization", String.to_charlist("token #{token()}")},
      {~c"Accept", ~c"application/vnd.github+json"},
      {~c"Content-Type", ~c"application/json"},
      {~c"User-Agent", ~c"sykli/0.1"}
    ]
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp description_for("pending", task), do: "Running #{task}..."
  defp description_for("success", task), do: "#{task} passed"
  defp description_for("failure", task), do: "#{task} failed"
  defp description_for("error", task), do: "#{task} errored"
end
