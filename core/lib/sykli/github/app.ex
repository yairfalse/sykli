defmodule Sykli.GitHub.App do
  @moduledoc "GitHub App authentication facade."

  @behaviour Sykli.GitHub.App.Behaviour

  @impl true
  def installation_token(installation_id, opts \\ []) do
    impl =
      Keyword.get(opts, :impl, Application.get_env(:sykli, :github_app_impl, __MODULE__.Real))

    impl.installation_token(installation_id, opts)
  end
end
