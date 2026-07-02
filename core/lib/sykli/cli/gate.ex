defmodule Sykli.CLI.Gate do
  @moduledoc """
  Local gate decision CLI commands.

  Local commands operate on `.sykli/gates`. Commands with `--team` use the
  Team Mode coordinator session and do not mutate the local gate store.
  """

  alias Sykli.CLI.JsonResponse
  alias Sykli.Daemon.SessionStore
  alias Sykli.Error
  alias Sykli.Error.Formatter
  alias Sykli.Gate.Store
  alias Sykli.GateDecision
  alias Sykli.TeamCoordinator.GateClient

  @default_actor_type "member"

  @doc """
  Runs a `sykli gate ...` or `sykli gates ...` command and returns the intended
  process exit code.

  `runtime_opts` are internal test hooks for store path, clocks, ids, and
  default actor attribution. Parsed CLI flags are kept separate in `opts`.
  """
  def run(args, runtime_opts \\ []) do
    case parse(args) do
      {:ok, command, opts} ->
        execute(command, opts, runtime_opts)

      {:error, reason, opts} ->
        output_error(reason, Keyword.get(opts, :json, false))
    end
  end

  defp execute(:list, opts, runtime_opts) do
    if team_mode?(opts) do
      list_team(opts, runtime_opts)
    else
      list_local(opts, runtime_opts)
    end
  end

  defp execute({:show, id}, opts, runtime_opts) do
    case Store.get(id, store_opts(runtime_opts)) do
      {:ok, gate} ->
        output_success(%{source: "local", gate: gate_map(gate)}, opts, fn ->
          print_gate(gate)
        end)

      {:error, reason} ->
        output_error(reason, Keyword.get(opts, :json, false))
    end
  end

  defp execute({:approve, id}, opts, runtime_opts) do
    decide(:approve, id, opts, runtime_opts)
  end

  defp execute({:reject, id}, opts, runtime_opts) do
    decide(:reject, id, opts, runtime_opts)
  end

  defp execute(:help, _opts, _runtime_opts) do
    print_help()
    0
  end

  defp list_local(opts, runtime_opts) do
    store_opts = store_opts(runtime_opts)

    result =
      case Keyword.get(opts, :status) do
        nil -> Store.list(store_opts)
        status -> Store.list_by_status(status, store_opts)
      end

    case result do
      {:ok, gates} ->
        output_success(%{source: "local", gates: Enum.map(gates, &gate_map/1)}, opts, fn ->
          if gates == [] do
            IO.puts("No gates")
          else
            IO.puts("Gates:")

            Enum.each(gates, fn gate ->
              IO.puts("  #{gate.id}  #{gate.status}  #{gate.node_id || "-"}")
            end)
          end
        end)

      {:error, reason} ->
        output_error(reason, Keyword.get(opts, :json, false))
    end
  end

  defp decide(action, id, opts, runtime_opts) do
    if team_mode?(opts) do
      decide_team(action, id, opts, runtime_opts)
    else
      decide_local(action, id, opts, runtime_opts)
    end
  end

  defp decide_local(action, id, opts, runtime_opts) do
    reason = Keyword.get(opts, :reason)
    {actor_type, actor_id} = actor(opts, runtime_opts)

    decision_opts =
      runtime_opts
      |> Keyword.take([:path, :now])
      |> Keyword.put(:decided_by, "#{actor_type}:#{actor_id}")

    result =
      case action do
        :approve -> Store.approve(id, reason, decision_opts)
        :reject -> Store.reject(id, reason, decision_opts)
      end

    case result do
      {:ok, gate} ->
        verb = if action == :approve, do: "Approved", else: "Rejected"

        output_success(%{source: "local", gate: gate_map(gate)}, opts, fn ->
          IO.puts("#{verb} gate #{gate.id}")
        end)

      {:error, reason} ->
        output_error(reason, Keyword.get(opts, :json, false))
    end
  end

  defp decide_team(action, id, opts, runtime_opts) do
    {actor_type, actor_id} = actor(opts, runtime_opts)
    status = if action == :approve, do: "approved", else: "rejected"

    with {:ok, session, token} <- team_session(opts, runtime_opts),
         {:ok, reason} <- required_reason(opts),
         {:ok, gate} <-
           gate_client(runtime_opts).record_decision(
             session,
             token,
             id,
             %{
               "status" => status,
               "decided_by" => "#{actor_type}:#{actor_id}",
               "decided_at" => now(runtime_opts),
               "reason" => reason
             },
             client_opts(runtime_opts)
           ) do
      verb = if action == :approve, do: "Approved", else: "Rejected"

      output_success(%{source: "team", team: session["team"], gate: gate}, opts, fn ->
        IO.puts("#{verb} team gate #{gate["id"]}")
      end)
    else
      {:error, reason} ->
        output_error(reason, Keyword.get(opts, :json, false))
    end
  end

  defp list_team(opts, runtime_opts) do
    with {:ok, session, token} <- team_session(opts, runtime_opts),
         {:ok, gates} <- gate_client(runtime_opts).list(session, token, client_opts(runtime_opts)) do
      output_success(%{source: "team", team: session["team"], gates: gates}, opts, fn ->
        if gates == [] do
          IO.puts("No team gates")
        else
          IO.puts("Team gates:")

          Enum.each(gates, fn gate ->
            IO.puts("  #{gate["id"]}  #{gate["status"]}  #{gate["node_id"] || "-"}")
          end)
        end
      end)
    else
      {:error, reason} ->
        output_error(reason, Keyword.get(opts, :json, false))
    end
  end

  defp parse(args) do
    {opts, positionals, error} = parse_flags(args, [], [])

    cond do
      error != nil ->
        {:error, error, opts}

      positionals in [[], ["--help"], ["-h"]] ->
        {:ok, :help, opts}

      positionals == ["list"] ->
        {:ok, :list, opts}

      match?(["show", _], positionals) ->
        ["show", id] = positionals
        {:ok, {:show, id}, opts}

      positionals == ["show"] ->
        {:error, {:invalid_gate_command, "show requires a gate id"}, opts}

      match?(["approve", _], positionals) ->
        ["approve", id] = positionals
        {:ok, {:approve, id}, opts}

      positionals == ["approve"] ->
        {:error, {:invalid_gate_command, "approve requires a gate id"}, opts}

      match?(["reject", _], positionals) ->
        ["reject", id] = positionals
        {:ok, {:reject, id}, opts}

      positionals == ["reject"] ->
        {:error, {:invalid_gate_command, "reject requires a gate id"}, opts}

      true ->
        {:error, {:invalid_gate_command, Enum.join(positionals, " ")}, opts}
    end
  end

  defp parse_flags([], opts, positionals),
    do: {Enum.reverse(opts), Enum.reverse(positionals), nil}

  defp parse_flags(["--json" | rest], opts, positionals) do
    parse_flags(rest, [{:json, true} | opts], positionals)
  end

  defp parse_flags(["--help" | rest], opts, positionals) do
    parse_flags(rest, opts, ["--help" | positionals])
  end

  defp parse_flags(["-h" | rest], opts, positionals) do
    parse_flags(rest, opts, ["-h" | positionals])
  end

  defp parse_flags(["--reason", value | rest], opts, positionals) do
    parse_flags(rest, [{:reason, value} | opts], positionals)
  end

  defp parse_flags([<<"--reason=", value::binary>> | rest], opts, positionals) do
    parse_flags(rest, [{:reason, value} | opts], positionals)
  end

  defp parse_flags(["--status", value | rest], opts, positionals) do
    parse_flags(rest, [{:status, value} | opts], positionals)
  end

  defp parse_flags([<<"--status=", value::binary>> | rest], opts, positionals) do
    parse_flags(rest, [{:status, value} | opts], positionals)
  end

  defp parse_flags(["--team", value | rest], opts, positionals) do
    parse_flags(rest, [{:team, value} | opts], positionals)
  end

  defp parse_flags([<<"--team=", value::binary>> | rest], opts, positionals) do
    parse_flags(rest, [{:team, value} | opts], positionals)
  end

  defp parse_flags(["--token", value | rest], opts, positionals) do
    parse_flags(rest, [{:token, value} | opts], positionals)
  end

  defp parse_flags([<<"--token=", value::binary>> | rest], opts, positionals) do
    parse_flags(rest, [{:token, value} | opts], positionals)
  end

  defp parse_flags(["--actor", value | rest], opts, positionals) do
    case parse_actor(value) do
      {:ok, actor_type, actor_id} ->
        parse_flags(rest, [{:actor_type, actor_type}, {:actor_id, actor_id} | opts], positionals)

      {:error, reason} ->
        finalize_parse_error(opts, positionals, rest, reason)
    end
  end

  defp parse_flags([<<"--actor=", value::binary>> | rest], opts, positionals) do
    case parse_actor(value) do
      {:ok, actor_type, actor_id} ->
        parse_flags(rest, [{:actor_type, actor_type}, {:actor_id, actor_id} | opts], positionals)

      {:error, reason} ->
        finalize_parse_error(opts, positionals, rest, reason)
    end
  end

  defp parse_flags([<<"--", _::binary>> = flag | rest], opts, positionals) do
    finalize_parse_error(opts, positionals, rest, {:unknown_gate_flag, flag})
  end

  defp parse_flags([arg | rest], opts, positionals) do
    parse_flags(rest, opts, [arg | positionals])
  end

  defp finalize_parse_error(opts, positionals, rest, reason) do
    opts =
      if "--json" in rest do
        [{:json, true} | opts]
      else
        opts
      end

    {Enum.reverse(opts), Enum.reverse(positionals), reason}
  end

  defp parse_actor(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [actor_type, actor_id] ->
        actor_type = String.trim(actor_type)
        actor_id = String.trim(actor_id)

        with :ok <- validate_actor_type(actor_type),
             :ok <- validate_cli_actor_id(actor_id) do
          {:ok, actor_type, actor_id}
        end

      _ ->
        {:error, {:invalid_gate_actor, value}}
    end
  end

  defp validate_actor_type(type) when type in ~w(member agent daemon system), do: :ok
  defp validate_actor_type(type), do: {:error, {:invalid_gate_requester_type, type}}

  defp validate_cli_actor_id(""), do: {:error, {:invalid_gate_actor, :empty_id}}
  defp validate_cli_actor_id(_actor_id), do: :ok

  defp actor(opts, runtime_opts) do
    {default_type, default_id} = default_actor(runtime_opts)

    {
      Keyword.get(opts, :actor_type, default_type),
      Keyword.get(opts, :actor_id, default_id)
    }
  end

  defp default_actor(runtime_opts) do
    {
      Keyword.get(runtime_opts, :default_actor_type, @default_actor_type),
      Keyword.get_lazy(runtime_opts, :default_actor_id, &default_actor_id/0)
    }
  end

  defp default_actor_id do
    ["SYKLI_ACTOR_ID", "USER", "USERNAME"]
    |> Enum.find_value(fn name ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
    |> case do
      nil -> "local"
      value -> value
    end
  end

  defp store_opts(runtime_opts), do: Keyword.take(runtime_opts, [:path])

  defp team_mode?(opts), do: Keyword.has_key?(opts, :team)

  defp team_session(opts, runtime_opts) do
    requested_team = Keyword.get(opts, :team)

    with {:ok, session} <- read_team_session(runtime_opts, requested_team),
         :ok <- validate_requested_team(session, requested_team),
         {:ok, token} <- team_token(opts, requested_team, runtime_opts) do
      {:ok, session, token}
    end
  end

  defp read_team_session(runtime_opts, requested_team) do
    case session_store(runtime_opts).read(path: Keyword.get(runtime_opts, :path)) do
      {:ok, session} -> {:ok, session}
      {:error, :daemon_session_not_found} -> {:error, {:gate_no_team_session, requested_team}}
      {:error, _reason} -> {:error, {:gate_no_team_session, requested_team}}
    end
  end

  defp validate_requested_team(_session, team) when team in [nil, ""],
    do: {:error, {:gate_no_team_session, team}}

  defp validate_requested_team(%{"team" => team}, team), do: :ok

  defp validate_requested_team(_session, requested_team),
    do: {:error, {:gate_no_team_session, requested_team}}

  defp team_token(opts, team, runtime_opts) do
    runtime_token =
      if Keyword.has_key?(runtime_opts, :team_token),
        do: Keyword.get(runtime_opts, :team_token),
        else: System.get_env("SYKLI_TEAM_TOKEN")

    case Keyword.get(opts, :token) || runtime_token do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, {:gate_missing_team_token, team}}, else: {:ok, value}

      _ ->
        {:error, {:gate_missing_team_token, team}}
    end
  end

  defp required_reason(opts) do
    case Keyword.get(opts, :reason) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :gate_decision_missing_reason}, else: {:ok, value}

      _ ->
        {:error, :gate_decision_missing_reason}
    end
  end

  defp now(runtime_opts) do
    case Keyword.get(runtime_opts, :now, DateTime.utc_now()) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      value when is_binary(value) -> value
    end
  end

  defp session_store(runtime_opts), do: Keyword.get(runtime_opts, :session_store, SessionStore)
  defp gate_client(runtime_opts), do: Keyword.get(runtime_opts, :gate_client, GateClient)
  defp client_opts(runtime_opts), do: Keyword.take(runtime_opts, [:client])

  defp output_success(data, opts, human_fun) do
    if Keyword.get(opts, :json, false) do
      IO.puts(JsonResponse.ok(data))
    else
      human_fun.()
    end

    0
  end

  defp output_error(reason, json_output) do
    error = gate_error(reason)

    if json_output do
      IO.puts(JsonResponse.error(error))
    else
      IO.puts(:stderr, Formatter.format(error))
    end

    1
  end

  defp gate_map(%GateDecision{} = gate), do: GateDecision.to_map(gate)

  defp gate_error({:gate_no_team_session, slug}), do: Error.gate_no_team_session(slug)
  defp gate_error({:gate_missing_team_token, slug}), do: Error.gate_missing_team_token(slug)

  defp gate_error({:team_coordinator_error, %{"code" => code, "message" => message} = error}) do
    %Error{
      code: code,
      type: :runtime,
      message: message,
      step: :setup,
      hints: Map.get(error, "hints", [])
    }
  end

  defp gate_error({:team_coordinator_unavailable, reason}),
    do: team_error("gate.coordinator_unavailable", "coordinator unavailable: #{inspect(reason)}")

  defp gate_error(:team_unauthorized),
    do: team_error("gate.team_unauthorized", "coordinator rejected gate authorization")

  defp gate_error(:team_invalid_coordinator_response),
    do: team_error("gate.invalid_coordinator_response", "coordinator returned invalid JSON")

  defp gate_error({:team_invalid_coordinator_response, _data}),
    do:
      team_error(
        "gate.invalid_coordinator_response",
        "coordinator returned an unexpected JSON shape"
      )

  defp gate_error(reason), do: Error.wrap(reason)

  defp team_error(code, message) do
    %Error{code: code, type: :runtime, message: message, step: :setup, hints: []}
  end

  defp print_gate(%GateDecision{} = gate) do
    IO.puts("#{gate.id}  #{gate.status}")

    if gate.work_item_id, do: IO.puts("work_item_id: #{gate.work_item_id}")
    if gate.run_id, do: IO.puts("run_id: #{gate.run_id}")
    if gate.node_id, do: IO.puts("node_id: #{gate.node_id}")
    if gate.reason, do: IO.puts("reason: #{gate.reason}")
    if gate.decided_by, do: IO.puts("decided_by: #{gate.decided_by}")
  end

  defp print_help do
    IO.puts("""
    Usage: sykli gate <command>
           sykli gates list

    Local gate decision commands.

    Unknown flags are rejected. Approval and rejection require --reason.

    Commands:
      sykli gates list [--status STATUS]
      sykli gate show <gate-id>
      sykli gate approve <gate-id> --reason TEXT [--actor TYPE:ID]
      sykli gate reject <gate-id> --reason TEXT [--actor TYPE:ID]

    Options:
      --json          Output as JSON
      --status STATUS Filter list output by gate status
      --reason TEXT   Decision reason for approve/reject
      --actor TYPE:ID Set actor identity, e.g. member:yair, agent:claude, daemon:worker-1
      --team SLUG     Use the joined Team Mode coordinator
      --token TOKEN   Team token; SYKLI_TEAM_TOKEN is also supported
    """)
  end
end
