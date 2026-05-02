defmodule Sykli.GitHub.Source do
  @moduledoc "GitHub source acquisition facade."

  @behaviour Sykli.GitHub.Source.Behaviour

  @impl true
  def acquire(context, token, opts \\ []) do
    impl =
      Keyword.get(opts, :impl, Application.get_env(:sykli, :github_source_impl, __MODULE__.Real))

    impl.acquire(context, token, opts)
  end

  @impl true
  def cleanup(path, opts \\ []) do
    impl =
      Keyword.get(opts, :impl, Application.get_env(:sykli, :github_source_impl, __MODULE__.Real))

    impl.cleanup(path, opts)
  end
end
