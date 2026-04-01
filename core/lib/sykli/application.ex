defmodule Sykli.Application do
  @moduledoc """
  Sykli OTP Application.

  Starts the supervision tree with:
  - ULID for monotonic event ID generation (AHTI compatible)
  - Phoenix.PubSub for event distribution
  - RunRegistry for tracking runs

  Registers a SIGTERM handler for graceful shutdown with a configurable
  drain timeout (default 30s, override via SYKLI_DRAIN_TIMEOUT_MS).
  """

  use Application

  require Logger

  @default_drain_timeout_ms 30_000

  @impl true
  def start(_type, _args) do
    children = [
      # ULID generator - must start first (other services may generate IDs on init)
      Sykli.ULID,

      # PubSub for events - works locally and across distributed nodes
      {Phoenix.PubSub, name: Sykli.PubSub},

      # Task supervisor for executor - isolates task crashes from executor
      {Task.Supervisor, name: Sykli.TaskSupervisor},

      # Run registry - tracks all local runs
      Sykli.RunRegistry
    ]

    # rest_for_one: if PubSub crashes, restart TaskSupervisor + RunRegistry
    opts = [strategy: :rest_for_one, name: Sykli.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Register SIGTERM handler for graceful shutdown
    register_signal_handler()

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

  @impl true
  def stop(_state) do
    drain_in_flight_tasks()
    :ok
  end

  # Register OS signal handler for SIGTERM to trigger graceful shutdown.
  # On SIGTERM: stop accepting new tasks, drain in-flight tasks, then exit.
  defp register_signal_handler do
    # :os.set_signal/2 available since OTP 26
    :os.set_signal(:sigterm, :handle)

    spawn(fn -> signal_loop() end)
  rescue
    # Gracefully handle older OTP versions that don't support set_signal
    UndefinedFunctionError -> :ok
  end

  defp signal_loop do
    receive do
      {:signal, :sigterm} ->
        Logger.info("[Sykli] SIGTERM received, starting graceful shutdown...")
        drain_in_flight_tasks()
        Logger.info("[Sykli] Drain complete, shutting down")
        System.stop(0)
    end
  end

  defp drain_in_flight_tasks do
    timeout = drain_timeout_ms()

    # Wait for all tasks under the TaskSupervisor to finish
    children = Task.Supervisor.children(Sykli.TaskSupervisor)

    if children != [] do
      Logger.info(
        "[Sykli] Draining #{length(children)} in-flight tasks (timeout: #{timeout}ms)..."
      )

      refs =
        Enum.map(children, fn pid ->
          ref = Process.monitor(pid)
          {pid, ref}
        end)

      deadline = System.monotonic_time(:millisecond) + timeout

      Enum.each(refs, fn {_pid, ref} ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          remaining ->
            Logger.warning("[Sykli] Drain timeout reached, forcing shutdown")
        end
      end)
    end
  end

  defp drain_timeout_ms do
    case System.get_env("SYKLI_DRAIN_TIMEOUT_MS") do
      nil -> @default_drain_timeout_ms
      val -> String.to_integer(val)
    end
  rescue
    _ -> @default_drain_timeout_ms
  end

  # Check if running as a Burrito-wrapped binary
  # Uses __BURRITO_BIN_PATH env var set by Burrito's Zig wrapper
  defp burrito? do
    System.get_env("__BURRITO_BIN_PATH") != nil
  end
end
