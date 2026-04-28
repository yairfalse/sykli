defmodule Sykli.GitHub.Clock.Fake do
  @moduledoc "Configurable clock for GitHub tests."

  @behaviour Sykli.GitHub.Clock

  @impl true
  def now_seconds, do: div(now_ms(), 1000)

  @impl true
  def now_ms do
    Application.get_env(:sykli, :github_clock_fake_now_ms, 1_700_000_000_000)
  end
end
