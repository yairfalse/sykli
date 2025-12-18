defmodule Sykli.Application do
  @moduledoc """
  Sykli OTP Application.

  Starts the supervision tree with:
  - Phoenix.PubSub for event distribution
  - RunRegistry for tracking runs
  - Executor.Server for stateful execution
  - Reporter for forwarding events to coordinator (when connected)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # PubSub for events - works locally and across distributed nodes
      {Phoenix.PubSub, name: Sykli.PubSub},

      # Run registry - tracks all local runs
      Sykli.RunRegistry,

      # Executor server - stateful execution with events
      Sykli.Executor.Server,

      # Reporter - forwards events to coordinator (if connected)
      Sykli.Reporter
    ]

    opts = [strategy: :one_for_one, name: Sykli.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
