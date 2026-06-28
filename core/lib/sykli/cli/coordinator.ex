defmodule Sykli.CLI.Coordinator do
  @moduledoc """
  Minimal CLI entry point for the self-hosted Team Mode coordinator skeleton.

  This command only starts the coordinator HTTP API. It does not join daemons,
  sync runs, sync gates, or execute remote work.
  """

  alias Sykli.CLI.JsonResponse
  alias Sykli.Error
  alias Sykli.Error.Formatter
  alias Sykli.TeamCoordinator.Auth

  @default_port 8620
  @default_bind "127.0.0.1"

  def run(args) do
    case parse(args) do
      {:ok, :help, _opts} ->
        print_help()
        0

      {:ok, :start, opts} ->
        start(opts)

      {:ok, :mint_token, opts} ->
        mint_token(opts)

      {:error, reason, opts} ->
        output_error(reason, Keyword.get(opts, :json, false))
    end
  end

  defp start(opts) do
    json? = Keyword.get(opts, :json, false)

    with {:ok, token} <- token(opts),
         {:ok, port} <- port(opts),
         {:ok, bind_string, bind_address} <- bind(opts),
         {:ok, _pid} <-
           Sykli.TeamCoordinator.Application.start_link(
             token: token,
             port: port,
             bind: bind_address
           ) do
      if json? do
        IO.puts(
          JsonResponse.ok(%{
            source: "coordinator",
            status: "running",
            bind: bind_string,
            port: port,
            storage: "in_memory"
          })
        )
      else
        IO.puts("Sykli coordinator listening on http://#{bind_string}:#{port}")
        IO.puts("storage: in_memory")
        IO.puts("warning: plain HTTP; terminate TLS at an ingress or proxy for production")
      end

      Process.sleep(:infinity)
      0
    else
      {:error, reason} -> output_error(reason, json?)
    end
  end

  defp parse(args) do
    {opts, positionals, error} = parse_flags(args, [], [])

    cond do
      error != nil ->
        {:error, error, opts}

      positionals in [[], ["--help"], ["-h"]] ->
        {:ok, :help, opts}

      positionals == ["start"] ->
        {:ok, :start, opts}

      positionals == ["mint-token"] ->
        {:ok, :mint_token, opts}

      true ->
        {:error, {:invalid_coordinator_command, Enum.join(positionals, " ")}, opts}
    end
  end

  defp parse_flags([], opts, positionals),
    do: {Enum.reverse(opts), Enum.reverse(positionals), nil}

  defp parse_flags(["--json" | rest], opts, positionals),
    do: parse_flags(rest, [{:json, true} | opts], positionals)

  defp parse_flags(["--help" | rest], opts, positionals),
    do: parse_flags(rest, opts, ["--help" | positionals])

  defp parse_flags(["-h" | rest], opts, positionals),
    do: parse_flags(rest, opts, ["-h" | positionals])

  defp parse_flags(["--port", value | rest], opts, positionals),
    do: parse_flags(rest, [{:port, value} | opts], positionals)

  defp parse_flags([<<"--port=", value::binary>> | rest], opts, positionals),
    do: parse_flags(rest, [{:port, value} | opts], positionals)

  defp parse_flags(["--bind", value | rest], opts, positionals),
    do: parse_flags(rest, [{:bind, value} | opts], positionals)

  defp parse_flags([<<"--bind=", value::binary>> | rest], opts, positionals),
    do: parse_flags(rest, [{:bind, value} | opts], positionals)

  defp parse_flags(["--token", value | rest], opts, positionals),
    do: parse_flags(rest, [{:token, value} | opts], positionals)

  defp parse_flags([<<"--token=", value::binary>> | rest], opts, positionals),
    do: parse_flags(rest, [{:token, value} | opts], positionals)

  defp parse_flags(["--org", value | rest], opts, positionals),
    do: parse_flags(rest, [{:org, value} | opts], positionals)

  defp parse_flags([<<"--org=", value::binary>> | rest], opts, positionals),
    do: parse_flags(rest, [{:org, value} | opts], positionals)

  defp parse_flags(["--team", value | rest], opts, positionals),
    do: parse_flags(rest, [{:team, value} | opts], positionals)

  defp parse_flags([<<"--team=", value::binary>> | rest], opts, positionals),
    do: parse_flags(rest, [{:team, value} | opts], positionals)

  defp parse_flags(["--role", value | rest], opts, positionals),
    do: parse_flags(rest, [{:role, value} | opts], positionals)

  defp parse_flags([<<"--role=", value::binary>> | rest], opts, positionals),
    do: parse_flags(rest, [{:role, value} | opts], positionals)

  defp parse_flags([<<"--", _::binary>> = flag | rest], opts, positionals) do
    opts =
      if "--json" in rest do
        [{:json, true} | opts]
      else
        opts
      end

    {Enum.reverse(opts), Enum.reverse(positionals), {:unknown_coordinator_flag, flag}}
  end

  defp parse_flags([arg | rest], opts, positionals),
    do: parse_flags(rest, opts, [arg | positionals])

  defp token(opts) do
    case Keyword.get(opts, :token) || System.get_env("SYKLI_COORDINATOR_TOKEN") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :coordinator_token_required}
    end
  end

  defp mint_token(opts) do
    json? = Keyword.get(opts, :json, false)

    with {:ok, admin_token} <- token(opts),
         {:ok, org} <- required_option(opts, :org),
         {:ok, team} <- required_option(opts, :team),
         {:ok, role} <- required_option(opts, :role),
         {:ok, token} <-
           Auth.mint_team_token(%{"org" => org, "team" => team, "role" => role},
             token: admin_token
           ) do
      if json? do
        IO.puts(JsonResponse.ok(%{token: token, org: org, team: team, role: role}))
      else
        IO.puts(token)
      end

      0
    else
      {:error, reason} -> output_error(reason, json?)
    end
  end

  defp required_option(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_coordinator_option, key}}
    end
  end

  defp port(opts) do
    value = Keyword.get(opts, :port, Integer.to_string(@default_port))

    case Integer.parse(value) do
      {port, ""} when port > 0 and port < 65_536 -> {:ok, port}
      _ -> {:error, {:invalid_coordinator_port, value}}
    end
  end

  defp bind(opts) do
    value = Keyword.get(opts, :bind, @default_bind)

    with {:ok, address} <- parse_bind(value) do
      {:ok, value, address}
    end
  end

  defp parse_bind(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> {:error, {:invalid_coordinator_bind, value}}
    end
  end

  defp output_error(reason, json_output) do
    error = coordinator_error(reason)

    if json_output do
      IO.puts(JsonResponse.error(error))
    else
      IO.puts(:stderr, Formatter.format(error))
    end

    1
  end

  defp coordinator_error(:coordinator_token_required) do
    %Error{
      code: "coordinator.token_required",
      type: :validation,
      message: "coordinator start requires a token",
      step: :setup,
      hints: ["set SYKLI_COORDINATOR_TOKEN or pass --token <token>"]
    }
  end

  defp coordinator_error({:missing_coordinator_option, key}) do
    %Error{
      code: "coordinator.invalid_command",
      type: :validation,
      message: "missing coordinator option: --#{String.replace(to_string(key), "_", "-")}",
      step: :validate,
      hints: ["use: sykli coordinator mint-token --org <slug> --team <slug> --role <role>"]
    }
  end

  defp coordinator_error(:coordinator_invalid_token_claims) do
    %Error{
      code: "coordinator.invalid_command",
      type: :validation,
      message: "invalid coordinator token claims",
      step: :validate,
      hints: ["role must be one of: owner, member, approver"]
    }
  end

  defp coordinator_error({:invalid_coordinator_port, value}) do
    %Error{
      code: "coordinator.invalid_port",
      type: :validation,
      message: "invalid coordinator port: #{inspect(value)}",
      step: :setup,
      hints: ["use --port with a TCP port between 1 and 65535"]
    }
  end

  defp coordinator_error({:invalid_coordinator_bind, value}) do
    %Error{
      code: "coordinator.invalid_bind",
      type: :validation,
      message: "invalid coordinator bind address: #{inspect(value)}",
      step: :setup,
      hints: ["use --bind with an IPv4 or IPv6 address, for example 127.0.0.1"]
    }
  end

  defp coordinator_error({:unknown_coordinator_flag, flag}) do
    %Error{
      code: "coordinator.invalid_command",
      type: :validation,
      message: "unknown coordinator flag: #{flag}",
      step: :validate,
      hints: ["use: sykli coordinator start --token <token>"]
    }
  end

  defp coordinator_error({:invalid_coordinator_command, command}) do
    %Error{
      code: "coordinator.invalid_command",
      type: :validation,
      message: "invalid coordinator command: #{command}",
      step: :validate,
      hints: ["use: sykli coordinator start --token <token>"]
    }
  end

  defp coordinator_error({:shutdown, {:failed_to_start_child, _child, reason}}) do
    %Error{
      code: "coordinator.start_failed",
      type: :runtime,
      message: "coordinator failed to start",
      step: :setup,
      cause: reason,
      hints: ["check whether the configured port is already in use"]
    }
  end

  defp coordinator_error(reason) do
    %Error{
      code: "coordinator.start_failed",
      type: :runtime,
      message: "coordinator failed to start: #{inspect(reason)}",
      step: :setup,
      hints: []
    }
  end

  defp print_help do
    IO.puts("""
    Usage: sykli coordinator <command>

    Self-hosted Team Mode coordinator commands.

    Commands:
      sykli coordinator start --token TOKEN [--port PORT] [--bind ADDRESS]
      sykli coordinator mint-token --org ORG --team TEAM --role ROLE --token TOKEN

    Options:
      --json          Output startup status as JSON before serving
      --token TOKEN   Bearer token required for non-health API endpoints
      --org ORG       Org slug for mint-token
      --team TEAM     Team slug for mint-token
      --role ROLE     Team token role: owner, member, or approver
      --port PORT     HTTP port (default: #{@default_port})
      --bind ADDRESS  Listen address (default: #{@default_bind}; use 0.0.0.0 only intentionally)

    The coordinator skeleton stores state in memory. It exposes health,
    org/team, work-item, run, gate (including gate decisions), and
    daemon-session/heartbeat endpoints; it never executes work.
    """)
  end
end
