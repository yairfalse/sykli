defmodule Sykli.Daemon.Leave do
  @moduledoc """
  CLI flow for leaving a self-hosted Team Mode coordinator.

  The inverse of `Sykli.Daemon.Join`: sends a best-effort final heartbeat
  with `status: "offline"` (when a team token is available) and removes the
  persisted session file. Leaving is idempotent — without a session it
  reports `left: false` and exits 0; coordination must never block local
  workflows, including its own teardown.
  """

  alias Sykli.CLI.JsonResponse
  alias Sykli.Coordinator.Client
  alias Sykli.Daemon.Join
  alias Sykli.Daemon.SessionStore
  alias Sykli.Error
  alias Sykli.Error.Formatter

  def run(args, runtime_opts \\ []) do
    case parse(args) do
      {:ok, :help} ->
        print_help()
        0

      {:ok, opts} ->
        leave(opts, runtime_opts)

      {:error, reason, opts} ->
        output_error(reason, Keyword.get(opts, :json, false))
    end
  end

  def leave(opts, runtime_opts \\ []) do
    json? = Keyword.get(opts, :json, false)
    store = Keyword.get(runtime_opts, :session_store, SessionStore)
    store_opts = Keyword.take(opts, [:path])

    case store.read(store_opts) do
      {:ok, session} ->
        notified = notify_offline(session, opts, runtime_opts)

        case store.delete(store_opts) do
          :ok ->
            output_left(session, notified, json?)

          {:error, reason} ->
            output_error({:session_delete_failed, reason}, json?)
        end

      {:error, _reason} ->
        output_not_joined(json?)
    end
  end

  # Best-effort: the coordinator marks the session offline on its own after
  # the liveness cutoff, so a failed (or token-less) notification must not
  # block the local teardown.
  defp notify_offline(session, opts, runtime_opts) do
    token =
      Keyword.get(opts, :token) ||
        System.get_env("SYKLI_TEAM_TOKEN")

    with t when is_binary(t) and t != "" <- token,
         payload = Join.heartbeat_payload(session, %{"status" => "offline"}),
         {:ok, _data} <- post_heartbeat(session, t, payload, runtime_opts) do
      true
    else
      _ -> false
    end
  end

  defp post_heartbeat(session, token, payload, runtime_opts) do
    client = Keyword.get(runtime_opts, :client, Client)

    client.post_json(
      session["coordinator"],
      "/v1/daemon-sessions/#{session["session_id"]}/heartbeat",
      token,
      payload
    )
  end

  defp output_left(session, notified, true) do
    IO.puts(
      JsonResponse.ok(%{
        left: true,
        session_id: session["session_id"],
        coordinator: session["coordinator"],
        coordinator_notified: notified
      })
    )

    0
  end

  defp output_left(session, notified, false) do
    IO.puts("Left coordinator #{session["coordinator"]}")

    unless notified do
      IO.puts(
        "Could not send the final offline heartbeat; the coordinator will " <>
          "mark the session offline after its liveness cutoff."
      )
    end

    0
  end

  defp output_not_joined(true) do
    IO.puts(JsonResponse.ok(%{left: false, reason: "not_joined"}))
    0
  end

  defp output_not_joined(false) do
    IO.puts("No coordinator session to leave.")
    0
  end

  defp parse(args) do
    case Enum.reduce_while(args, {[], []}, &collect_flag/2) do
      {:error, reason, opts} -> {:error, reason, opts}
      {opts, ["leave"]} -> route(opts)
      {opts, []} -> route(opts)
      {_opts, positionals} -> {:error, {:invalid_daemon_leave_command, positionals}, []}
    end
  end

  defp route(opts) do
    if Keyword.get(opts, :help, false), do: {:ok, :help}, else: {:ok, opts}
  end

  defp collect_flag("--json", {opts, pos}), do: {:cont, {[{:json, true} | opts], pos}}
  defp collect_flag("--help", {opts, pos}), do: {:cont, {[{:help, true} | opts], pos}}
  defp collect_flag("-h", {opts, pos}), do: {:cont, {[{:help, true} | opts], pos}}

  defp collect_flag("--token", {opts, pos}), do: {:cont, {[{:token_next, true} | opts], pos}}

  defp collect_flag(<<"--token=", value::binary>>, {opts, pos}),
    do: {:cont, {[{:token, value} | opts], pos}}

  defp collect_flag(<<"--", _::binary>> = flag, {opts, _pos}),
    do: {:halt, {:error, {:unknown_daemon_leave_flag, flag}, opts}}

  defp collect_flag(value, {opts, pos}) do
    if Keyword.get(opts, :token_next, false) do
      {:cont, {[{:token, value} | Keyword.delete(opts, :token_next)], pos}}
    else
      {:cont, {opts, pos ++ [value]}}
    end
  end

  defp output_error(reason, json?) do
    error = leave_error(reason)

    if json? do
      IO.puts(JsonResponse.error(error))
    else
      IO.puts(:stderr, Formatter.format(error))
    end

    1
  end

  defp leave_error({:unknown_daemon_leave_flag, flag}),
    do: validation("daemon.invalid_leave_command", "unknown daemon leave flag: #{flag}")

  defp leave_error({:invalid_daemon_leave_command, positionals}),
    do:
      validation(
        "daemon.invalid_leave_command",
        "invalid daemon leave command: #{Enum.join(positionals, " ")}"
      )

  defp leave_error({:session_delete_failed, reason}),
    do:
      runtime(
        "daemon.leave_failed",
        "could not remove the local session file: #{inspect(reason)}"
      )

  defp validation(code, message),
    do: %Error{code: code, type: :validation, message: message, step: :validate, hints: []}

  defp runtime(code, message),
    do: %Error{code: code, type: :runtime, message: message, step: :setup, hints: []}

  defp print_help do
    IO.puts("""
    Usage: sykli daemon leave [options]

    Leave the joined Team Mode coordinator: send a best-effort final
    offline heartbeat and remove the local session. Idempotent — leaving
    without a session succeeds with left: false.

    Options:
      --json           Output JSON
      --token TOKEN    Team token for the offline notification;
                       SYKLI_TEAM_TOKEN is also supported
    """)
  end
end
