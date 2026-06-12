defmodule Sykli.Daemon.Join do
  @moduledoc """
  CLI/client flow for joining a self-hosted Team Mode coordinator.
  """

  alias Sykli.CLI.JsonResponse
  alias Sykli.Coordinator.Client
  alias Sykli.Daemon.SessionStore
  alias Sykli.Error
  alias Sykli.Error.Formatter

  require Logger

  @gate_apply_retry_cap 10

  def run(args, runtime_opts \\ []) do
    case parse(args) do
      {:ok, :help, _opts} ->
        print_help()
        0

      {:ok, opts} ->
        join(opts, runtime_opts)

      {:error, reason, opts} ->
        output_error(reason, Keyword.get(opts, :json, false))
    end
  end

  def join(opts, runtime_opts \\ []) do
    json? = Keyword.get(opts, :json, false)

    with {:ok, payload} <- build_join_payload(opts, runtime_opts),
         {:ok, token} <- required_opt(opts, :token, :daemon_join_missing_token),
         {:ok, data} <-
           apply(client(runtime_opts), :post_json, [
             Keyword.fetch!(opts, :coordinator),
             "/v1/daemon-sessions",
             token,
             payload
           ]),
         {:ok, persisted} <- persist_session(opts, payload, data, runtime_opts) do
      output_success(persisted, json?)

      if Keyword.get(opts, :stay, false) do
        stay(persisted, opts, runtime_opts)
      else
        0
      end
    else
      {:error, reason} -> output_error(reason, json?)
    end
  end

  # Foreground heartbeat host: runs the loop in the current process's
  # supervision-free world and blocks until it stops (token revoked, session
  # refused, or operator interrupt). The minimal Team Mode daemon — no BEAM
  # distribution, no mesh.
  defp stay(session, opts, runtime_opts) do
    heartbeat = Keyword.get(runtime_opts, :heartbeat, Sykli.Daemon.Heartbeat)

    start_opts =
      [
        name: nil,
        session: session,
        token: Keyword.get(opts, :token) || System.get_env("SYKLI_TEAM_TOKEN")
      ] ++ Keyword.take(opts, [:path])

    case heartbeat.start_link(start_opts) do
      {:ok, pid} ->
        unless Keyword.get(opts, :json, false) do
          IO.puts("Heartbeat loop running. Ctrl-C to stop.")
        end

        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> 0
        end

      :ignore ->
        output_error(:daemon_stay_failed, Keyword.get(opts, :json, false))

      {:error, reason} ->
        output_error({:daemon_stay_failed, reason}, Keyword.get(opts, :json, false))
    end
  end

  def build_join_payload(opts, runtime_opts \\ []) do
    with {:ok, _coordinator} <-
           required_opt(opts, :coordinator, :daemon_join_missing_coordinator),
         {:ok, org} <- required_opt(opts, :org, :daemon_join_missing_org),
         {:ok, team} <- required_opt(opts, :team, :daemon_join_missing_team),
         {:ok, _token} <- required_opt(opts, :token, :daemon_join_missing_token),
         {:ok, labels} <- parse_list(Keyword.get(opts, :labels, ""), :labels),
         {:ok, capabilities} <-
           parse_capabilities(Keyword.get(opts, :capabilities), runtime_opts),
         {:ok, daemon_id} <- daemon_id(opts) do
      {:ok,
       %{
         "daemon_id" => daemon_id,
         "org" => org,
         "team" => team,
         "labels" => labels,
         "capabilities" => capabilities,
         "version" => version(runtime_opts),
         "accepts_remote_work" => Keyword.get(opts, :accepts_remote_work, false)
       }}
    end
  end

  def heartbeat_payload(session, attrs \\ %{}) do
    %{
      "session_id" => session["session_id"],
      "status" => Map.get(attrs, "status", "available"),
      "current_work_item_id" => Map.get(attrs, "current_work_item_id"),
      "labels" => Map.get(attrs, "labels", session["labels"] || []),
      "capabilities" => Map.get(attrs, "capabilities", session["capabilities"] || []),
      "last_run_id" => Map.get(attrs, "last_run_id"),
      "acknowledged_decision_ids" => Map.get(attrs, "acknowledged_decision_ids", [])
    }
  end

  def apply_heartbeat_response(response, opts \\ []) when is_map(response) do
    decisions = Map.get(response, "decisions", [])

    decisions
    |> Enum.reduce({:ok, []}, fn
      decision, {:ok, acked} when is_map(decision) ->
        case Sykli.Gate.Store.apply_remote_decision(decision, opts) do
          {:ok, _gate, _mode} ->
            reset_gate_apply_failures(decision, opts)
            {:ok, [decision["id"] | acked]}

          {:error, reason} ->
            if record_gate_apply_failure(decision, reason, opts) > @gate_apply_retry_cap do
              Logger.error("dropping gate decision after repeated local apply failures",
                id: decision["id"],
                reason: inspect(reason)
              )

              {:ok, [decision["id"] | acked]}
            else
              {:ok, acked}
            end
        end

      _decision, {:ok, acked} ->
        {:ok, acked}
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(Enum.reject(ids, &is_nil/1))}
    end
  end

  defp record_gate_apply_failure(decision, reason, opts) do
    id = decision["id"]
    key = gate_apply_failure_key(id, opts)
    count = Process.get(key, 0) + 1
    Process.put(key, count)

    Logger.warning("failed to apply remote gate decision",
      id: id,
      reason: inspect(reason),
      attempt: count
    )

    Sykli.Occurrence.PubSub.team_gate_apply_failed(decision["run_id"] || "unknown", %{
      "id" => id,
      "reason" => inspect(reason)
    })

    count
  end

  defp reset_gate_apply_failures(decision, opts) do
    Process.delete(gate_apply_failure_key(decision["id"], opts))
    :ok
  end

  defp gate_apply_failure_key(id, opts) do
    session_id = Keyword.get(opts, :session_id, :default)
    {__MODULE__, :gate_apply_failure, session_id, id}
  end

  defp persist_session(opts, payload, data, runtime_opts) do
    session = %{
      "coordinator" => Keyword.fetch!(opts, :coordinator),
      "org" => payload["org"],
      "team" => payload["team"],
      "daemon_id" => payload["daemon_id"],
      "session_id" => data["session_id"],
      "team_id" => data["team_id"],
      "heartbeat_interval_seconds" => data["heartbeat_interval_seconds"],
      "policy" => data["policy"],
      "labels" => payload["labels"],
      "capabilities" => payload["capabilities"],
      "accepts_remote_work" => payload["accepts_remote_work"],
      "joined_at" => now(runtime_opts)
    }

    session_store(runtime_opts).write(session, path: Keyword.get(opts, :path))
  end

  defp output_success(session, true) do
    IO.puts(JsonResponse.ok(%{session: public_session(session)}))
    0
  end

  defp output_success(session, false) do
    IO.puts("Joined coordinator #{session["coordinator"]}")
    IO.puts("session_id: #{session["session_id"]}")
    IO.puts("team_id: #{session["team_id"]}")
    IO.puts("accepts_remote_work: #{session["accepts_remote_work"]}")
    0
  end

  defp public_session(session), do: Map.drop(session, ["token"])

  defp parse(args) do
    {opts, positionals, error} = parse_flags(args, [], [])

    cond do
      error != nil -> {:error, error, opts}
      positionals in [[], ["--help"], ["-h"]] -> {:ok, :help, opts}
      positionals in [["join", "--help"], ["join", "-h"]] -> {:ok, :help, opts}
      positionals == ["join"] -> {:ok, opts}
      true -> {:error, {:invalid_daemon_join_command, Enum.join(positionals, " ")}, opts}
    end
  end

  defp parse_flags([], opts, positionals),
    do: {Enum.reverse(opts), Enum.reverse(positionals), nil}

  defp parse_flags(["--json" | rest], opts, pos),
    do: parse_flags(rest, [{:json, true} | opts], pos)

  defp parse_flags(["--help" | rest], opts, pos), do: parse_flags(rest, opts, ["--help" | pos])
  defp parse_flags(["-h" | rest], opts, pos), do: parse_flags(rest, opts, ["-h" | pos])

  defp parse_flags(["--accept-remote-work" | rest], opts, pos),
    do: parse_flags(rest, [{:accepts_remote_work, true} | opts], pos)

  defp parse_flags(["--stay" | rest], opts, pos),
    do: parse_flags(rest, [{:stay, true} | opts], pos)

  defp parse_flags(["--coordinator", value | rest], opts, pos),
    do: parse_flags(rest, [{:coordinator, value} | opts], pos)

  defp parse_flags([<<"--coordinator=", value::binary>> | rest], opts, pos),
    do: parse_flags(rest, [{:coordinator, value} | opts], pos)

  defp parse_flags(["--org", value | rest], opts, pos),
    do: parse_flags(rest, [{:org, value} | opts], pos)

  defp parse_flags([<<"--org=", value::binary>> | rest], opts, pos),
    do: parse_flags(rest, [{:org, value} | opts], pos)

  defp parse_flags(["--team", value | rest], opts, pos),
    do: parse_flags(rest, [{:team, value} | opts], pos)

  defp parse_flags([<<"--team=", value::binary>> | rest], opts, pos),
    do: parse_flags(rest, [{:team, value} | opts], pos)

  defp parse_flags(["--token", value | rest], opts, pos),
    do: parse_flags(rest, [{:token, value} | opts], pos)

  defp parse_flags([<<"--token=", value::binary>> | rest], opts, pos),
    do: parse_flags(rest, [{:token, value} | opts], pos)

  defp parse_flags(["--labels", value | rest], opts, pos),
    do: parse_flags(rest, [{:labels, value} | opts], pos)

  defp parse_flags([<<"--labels=", value::binary>> | rest], opts, pos),
    do: parse_flags(rest, [{:labels, value} | opts], pos)

  defp parse_flags(["--capabilities", value | rest], opts, pos),
    do: parse_flags(rest, [{:capabilities, value} | opts], pos)

  defp parse_flags([<<"--capabilities=", value::binary>> | rest], opts, pos),
    do: parse_flags(rest, [{:capabilities, value} | opts], pos)

  defp parse_flags(["--name", value | rest], opts, pos),
    do: parse_flags(rest, [{:name, value} | opts], pos)

  defp parse_flags([<<"--name=", value::binary>> | rest], opts, pos),
    do: parse_flags(rest, [{:name, value} | opts], pos)

  defp parse_flags([<<"--", _::binary>> = flag | _rest], opts, pos),
    do: {Enum.reverse(opts), Enum.reverse(pos), {:unknown_daemon_join_flag, flag}}

  defp parse_flags([arg | rest], opts, pos), do: parse_flags(rest, opts, [arg | pos])

  defp required_opt(opts, key, reason) do
    case Keyword.get(opts, key) || env_for(key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, reason}, else: {:ok, value}

      _ ->
        {:error, reason}
    end
  end

  defp env_for(:token), do: System.get_env("SYKLI_TEAM_TOKEN")
  defp env_for(_key), do: nil

  defp parse_capabilities(nil, runtime_opts),
    do: {:ok, Keyword.get(runtime_opts, :default_capabilities, ["local"])}

  defp parse_capabilities(value, _runtime_opts), do: parse_list(value, :capabilities)

  defp parse_list(value, field) when is_binary(value) do
    values =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if Enum.all?(values, &valid_list_value?/1),
      do: {:ok, values},
      else: {:error, {:invalid_daemon_list, field}}
  end

  defp valid_list_value?(value),
    do: String.length(value) <= 128 and Regex.match?(~r/^[a-zA-Z0-9._-]+$/, value)

  defp daemon_id(opts) do
    value = Keyword.get(opts, :name) || Sykli.Daemon.get_hostname()
    value = String.downcase(value)

    if Regex.match?(~r/^[a-z0-9._-]{1,128}$/, value),
      do: {:ok, value},
      else: {:error, {:invalid_daemon_id, value}}
  end

  defp version(runtime_opts),
    do: Keyword.get(runtime_opts, :version, Application.spec(:sykli, :vsn) |> to_string())

  defp now(runtime_opts) do
    case Keyword.get(runtime_opts, :now, DateTime.utc_now()) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      value when is_binary(value) -> value
    end
  end

  defp client(runtime_opts), do: Keyword.get(runtime_opts, :client, Client)
  defp session_store(runtime_opts), do: Keyword.get(runtime_opts, :session_store, SessionStore)

  defp output_error(reason, json?) do
    error = join_error(reason)

    if json? do
      IO.puts(JsonResponse.error(error))
    else
      IO.puts(:stderr, Formatter.format(error))
    end

    1
  end

  defp join_error(:daemon_join_missing_coordinator),
    do: validation("daemon.join_missing_coordinator", "daemon join requires --coordinator")

  defp join_error(:daemon_join_missing_org),
    do: validation("daemon.join_missing_org", "daemon join requires --org")

  defp join_error(:daemon_join_missing_team),
    do: validation("daemon.join_missing_team", "daemon join requires --team")

  defp join_error(:daemon_join_missing_token),
    do:
      validation("daemon.join_missing_token", "daemon join requires --token or SYKLI_TEAM_TOKEN")

  defp join_error({:invalid_daemon_id, id}),
    do: validation("daemon.invalid_id", "invalid daemon id: #{inspect(id)}")

  defp join_error({:invalid_daemon_list, field}),
    do: validation("daemon.invalid_join_payload", "invalid comma-separated #{field}")

  defp join_error({:unknown_daemon_join_flag, flag}),
    do: validation("daemon.invalid_join_command", "unknown daemon join flag: #{flag}")

  defp join_error({:invalid_daemon_join_command, command}),
    do: validation("daemon.invalid_join_command", "invalid daemon join command: #{command}")

  defp join_error(:daemon_stay_failed),
    do:
      runtime(
        "daemon.stay_failed",
        "heartbeat loop refused to start: missing session or team token"
      )

  defp join_error({:daemon_stay_failed, reason}),
    do: runtime("daemon.stay_failed", "heartbeat loop failed to start: #{inspect(reason)}")

  defp join_error({:coordinator_unavailable, reason}),
    do: runtime("daemon.coordinator_unavailable", "coordinator unavailable: #{inspect(reason)}")

  defp join_error({:coordinator_error, 401, _error}),
    do:
      runtime("daemon.coordinator_unauthorized", "coordinator rejected daemon join authorization")

  defp join_error({:coordinator_error, _status, %{"message" => message}}),
    do: runtime("daemon.coordinator_error", "coordinator rejected daemon join: #{message}")

  defp join_error(:invalid_coordinator_response),
    do: runtime("daemon.invalid_coordinator_response", "coordinator returned invalid JSON")

  defp join_error({:invalid_coordinator_response, _}),
    do:
      runtime(
        "daemon.invalid_coordinator_response",
        "coordinator returned an unexpected JSON shape"
      )

  defp join_error(reason),
    do: runtime("daemon.join_failed", "daemon join failed: #{inspect(reason)}")

  defp validation(code, message),
    do: %Error{code: code, type: :validation, message: message, step: :validate, hints: []}

  defp runtime(code, message),
    do: %Error{code: code, type: :runtime, message: message, step: :setup, hints: []}

  defp print_help do
    IO.puts("""
    Usage: sykli daemon join --coordinator URL --org ORG --team TEAM --token TOKEN [options]

    Join a self-hosted Team Mode coordinator. This registers daemon presence
    only; it does not enable remote execution.

    Options:
      --json                    Output JSON
      --coordinator URL         Coordinator base URL
      --org SLUG                Org slug
      --team SLUG               Team slug
      --token TOKEN             Team token; SYKLI_TEAM_TOKEN is also supported
      --labels LIST             Comma-separated labels, e.g. macos,docker
      --capabilities LIST       Comma-separated capabilities, default: local
      --name NAME               Stable daemon id, default: hostname
      --accept-remote-work      Explicitly advertise remote-work acceptance
      --stay                    Keep running: heartbeat loop in the foreground

    Remote work is disabled by default. Without --stay, join registers the
    session and exits; gate decisions are then picked up only while a daemon
    or a --stay loop is running.
    """)
  end
end
