defmodule Sykli.GitHub.Source do
  @moduledoc "GitHub source acquisition facade."

  @behaviour Sykli.GitHub.Source.Behaviour

  @impl true
  def acquire(context, token, opts \\ []) do
    source_impl(opts).acquire(context, token, opts)
  end

  @impl true
  def cleanup(path, opts \\ []) do
    source_impl(opts).cleanup(path, opts)
  end

  defp source_impl(opts) do
    Keyword.get(
      opts,
      :source_impl,
      Keyword.get(opts, :impl, Application.get_env(:sykli, :github_source_impl, __MODULE__.Real))
    )
  end
end
