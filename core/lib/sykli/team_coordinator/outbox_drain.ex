defmodule Sykli.TeamCoordinator.OutboxDrain do
  @moduledoc """
  Shared drain path for deferred Team Mode sync payloads.

  Used by the CLI post-run sync and the daemon heartbeat loop. Reads the
  local daemon session and the team token from the environment and quietly
  no-ops when either is absent — no session means no network (local-first).

  Extracted from the CLI so both callers replay `.sykli/outbox/` through
  one code path.
  """

  alias Sykli.Daemon.SessionStore
  alias Sykli.Occurrence.PubSub

  @doc """
  Drain both Team Mode outboxes (runs, then gates). Always returns `:ok`.
  """
  def drain_all(opts \\ []) do
    drain_runs(opts)
    drain_gates(opts)
    :ok
  end

  def drain_runs(opts \\ []) do
    with_session_and_token(opts, fn session, token ->
      result =
        Sykli.Outbox.drain(
          "runs",
          fn payload ->
            Sykli.TeamCoordinator.RunClient.publish_raw(session, token, payload)
          end,
          outbox_opts(opts)
        )

      count_synced = synced_count(result)

      if count_synced > 0 do
        remaining =
          case Sykli.Outbox.pending_count("runs", outbox_opts(opts)) do
            {:ok, count} -> count
            {:error, _reason} -> 0
          end

        PubSub.team_outbox_drained("team-outbox", %{
          "count_synced" => count_synced,
          "count_remaining" => remaining
        })
      end

      :ok
    end)
  end

  def drain_gates(opts \\ []) do
    with_session_and_token(opts, fn session, token ->
      result =
        Sykli.Outbox.drain(
          "gates",
          fn payload ->
            if payload["daemon_session_id"] == session["session_id"] do
              Sykli.TeamCoordinator.GateClient.publish_raw(session, token, payload)
            else
              {:error, :team_gate_invalid_payload}
            end
          end,
          outbox_opts(opts)
        )

      count_synced = synced_count(result)

      if count_synced > 0 do
        PubSub.team_outbox_drained("team-outbox", %{
          "kind" => "gates",
          "count_synced" => count_synced
        })
      end

      :ok
    end)
  end

  defp with_session_and_token(opts, fun) do
    session_result =
      case Keyword.fetch(opts, :session) do
        {:ok, session} when is_map(session) -> {:ok, session}
        _ -> SessionStore.read(session_opts(opts))
      end

    token = Keyword.get(opts, :token) || System.get_env("SYKLI_TEAM_TOKEN")

    with {:ok, session} <- session_result,
         t when is_binary(t) and t != "" <- token do
      fun.(session, t)
    else
      _ -> :ok
    end
  end

  defp synced_count({:ok, count}), do: count
  defp synced_count({:error, count, _reason}), do: count

  # `:path` here is the workdir (matching the executor's `Outbox.enqueue(..., path: workdir)`
  # and `Outbox`'s own convention). Threading it makes the drain read the same
  # `.sykli/outbox/` the enqueue wrote, instead of defaulting to cwd (#203).
  defp outbox_opts(opts) do
    case Keyword.get(opts, :path) do
      nil -> []
      path -> [path: path]
    end
  end

  # SessionStore takes the `.sykli` directory, which lives under the workdir.
  defp session_opts(opts) do
    case Keyword.get(opts, :path) do
      nil -> []
      path -> [path: Path.join(path, ".sykli")]
    end
  end
end
