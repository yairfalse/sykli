defmodule Sykli.Application do
  @moduledoc """
  Sykli OTP Application.

  Starts the supervision tree with:
  - ULID for monotonic event ID generation (AHTI compatible)
  - Phoenix.PubSub for event distribution
  - RunRegistry for tracking runs
  - Executor.Server for stateful execution
  - Reporter for forwarding events to coordinator (when connected)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ULID generator - must start first (other services may generate IDs on init)
      Sykli.ULID,

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
    result = Supervisor.start_link(children, opts)

    # If running as Burrito binary, invoke CLI
    # Clear the env var immediately to prevent subprocess inheritance
    # (otherwise mix test would trigger CLI.main too!)
    if burrito?() do
      System.delete_env("__BURRITO_BIN_PATH")
      args = Burrito.Util.Args.argv()
      Sykli.CLI.main(args)
    end

    result
  end

  # Check if running as a Burrito-wrapped binary
  # Uses __BURRITO_BIN_PATH env var set by Burrito's Zig wrapper
  defp burrito? do
    System.get_env("__BURRITO_BIN_PATH") != nil
  end
end
