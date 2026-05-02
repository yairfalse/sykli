defmodule Sykli.GitHub.App.Fake do
  @moduledoc "Fake GitHub App client for tests."

  @behaviour Sykli.GitHub.App.Behaviour

  @impl true
  def installation_token(installation_id, opts \\ []) do
    case Keyword.get(opts, :app_response, :default) do
      :default ->
        token = Keyword.get(opts, :token, "fake-installation-token-#{installation_id}")
        expires_at = Keyword.get(opts, :expires_at, 4_102_444_800)
        {:ok, token, expires_at}

      response ->
        response
    end
  end
end
