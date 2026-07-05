defmodule Sykli.Daemon.Heartbeat do
  @moduledoc """
  The Team Mode heartbeat loop (docs/daemon-join-protocol.md).

  Periodically POSTs the daemon heartbeat to the joined coordinator, applies
  returned gate decisions through `Sykli.Daemon.Join.apply_heartbeat_response/2`,
  acknowledges them on the following tick, and drains the Team Mode outbox on
  reconnect.

  Protocol behavior implemented here:

    * the coordinator owns the cadence — `next_heartbeat_seconds` from each
      response schedules the next tick (fallback: the session's
      `heartbeat_interval_seconds`);
    * network/5xx failures back off exponentially with jitter, capped at
      `heartbeat_interval_seconds * 4`;
    * 401/403 stops the loop and surfaces `team.token.revoked` — the token is
      never retried;
    * assignments received while `accepts_remote_work` is false are refused
      and logged (`team.policy.refused_remote_work`);
    * the first successful heartbeat after a failure (or after startup)
      drains `.sykli/outbox/`.

  Local-first is binding: without a persisted session and a team token the
  loop refuses to start (`:ignore`), and a coordination failure never blocks
  local execution — it only delays this process's next tick.

  The process is intended to run under `restart: :transient` so a protocol
  stop (token revoked, session refused) is not resurrected into a retry storm.
  """

  use GenServer, restart: :transient

  alias Sykli.Coordinator.Client
  alias Sykli.Daemon.Join
  alias Sykli.Daemon.SessionStore

  require Logger

  @default_interval_seconds 15
  @backoff_cap_multiplier 4

  defstruct session: nil,
            token: nil,
            interval: @default_interval_seconds,
            failures: 0,
            pending_acks: [],
            status: "available",
            synced_once: false,
            opts: []

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Current loop state for status surfaces. Returns a map."
  def info(server \\ __MODULE__) do
    GenServer.call(server, :info)
  end

  @doc "Mark the daemon as draining; the next heartbeat reports it."
  def drain(server \\ __MODULE__) do
    GenServer.cast(server, :drain)
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    session_result =
      case Keyword.fetch(opts, :session) do
        {:ok, session} when is_map(session) -> {:ok, session}
        _ -> session_store(opts).read(session_store_opts(opts))
      end

    token = Keyword.get(opts, :token) || System.get_env("SYKLI_TEAM_TOKEN")

    with {:ok, session} <- session_result,
         t when is_binary(t) and t != "" <- token do
      # Trap exits so terminate/2 can send a best-effort final offline
      # heartbeat on supervisor shutdown (graceful disconnect, protocol §
      # "Disconnect and reconnect").
      Process.flag(:trap_exit, true)

      interval = interval_seconds(session)

      state = %__MODULE__{
        session: session,
        token: t,
        interval: interval,
        opts: opts
      }

      schedule(state, Keyword.get(opts, :initial_delay_ms, 0))
      {:ok, state}
    else
      _ ->
        Logger.debug("heartbeat loop not started: no coordinator session or team token")
        :ignore
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       session_id: state.session["session_id"],
       coordinator: state.session["coordinator"],
       interval_seconds: state.interval,
       consecutive_failures: state.failures,
       status: state.status
     }, state}
  end

  @impl true
  def handle_cast(:drain, state) do
    {:noreply, %{state | status: "draining"}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    payload =
      Join.heartbeat_payload(state.session, %{
        "status" => state.status,
        "acknowledged_decision_ids" => state.pending_acks
      })

    case post_heartbeat(state, payload) do
      {:ok, data} ->
        handle_success(state, data)

      {:error, {:coordinator_error, status, _error}} when status in [401, 403] ->
        Logger.error(
          "team.token.revoked: coordinator rejected the team token; " <>
            "stopping heartbeat loop. Rotate the token and rejoin."
        )

        persist_liveness(state, %{"revoked" => true})
        {:stop, :normal, state}

      {:error, {:coordinator_error, 404, %{"code" => "coordinator.daemon_session_not_found"}}} ->
        rejoin(state)

      {:error, reason} ->
        handle_failure(state, reason)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.synced_once do
      payload = Join.heartbeat_payload(state.session, %{"status" => "offline"})

      # The goodbye is a courtesy, and the transport may already be gone
      # while we shut down (:inets stopped during VM drain, injected test
      # transports torn down first) — a failed offline heartbeat must not
      # turn a clean stop into a crash.
      try do
        post_heartbeat(state, payload)
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end

  # ── Tick outcomes ───────────────────────────────────────────────────────

  defp handle_success(state, data) do
    if state.failures > 0 or not state.synced_once do
      outbox_drain(state).()
    end

    refuse_unconsented_assignments(state, data)

    apply_opts =
      Keyword.merge(
        [session_id: state.session["session_id"]],
        Keyword.get(state.opts, :gate_opts, [])
      )

    {:ok, acks} = Join.apply_heartbeat_response(data, apply_opts)

    next_seconds = positive_integer(data["next_heartbeat_seconds"], state.interval)

    persist_liveness(state, %{"consecutive_failures" => 0})

    state = %{state | failures: 0, pending_acks: acks, synced_once: true}
    schedule(state, next_seconds * 1000)
    {:noreply, state}
  end

  defp handle_failure(state, reason) do
    failures = state.failures + 1
    delay_ms = backoff_ms(state.interval, failures, state.opts)

    Logger.warning(
      "heartbeat failed (attempt #{failures}); retrying in #{delay_ms}ms: #{inspect(reason)}"
    )

    persist_liveness(state, %{"consecutive_failures" => failures})

    state = %{state | failures: failures}
    schedule(state, delay_ms)
    {:noreply, state}
  end

  # The coordinator no longer knows our session (restart, cutoff exceeded).
  # The protocol blesses an automatic fresh join: same daemon identity, new
  # session_id, rejoin recorded by the coordinator's audit log.
  defp rejoin(state) do
    payload = %{
      "daemon_id" => state.session["daemon_id"],
      "org" => state.session["org"],
      "team" => state.session["team"],
      "labels" => state.session["labels"] || [],
      "capabilities" => state.session["capabilities"] || [],
      "version" => Application.spec(:sykli, :vsn) |> to_string(),
      "accepts_remote_work" => state.session["accepts_remote_work"] == true
    }

    case post_join(state, payload) do
      {:ok, data} ->
        session =
          state.session
          |> Map.merge(
            Map.take(data, ["session_id", "team_id", "heartbeat_interval_seconds", "policy"])
          )
          |> Map.delete("revoked")

        Logger.info("heartbeat session expired; rejoined coordinator as #{session["session_id"]}")

        state = %{state | session: session, interval: interval_seconds(session), failures: 0}
        persist_liveness(state, %{"consecutive_failures" => 0})
        schedule(state, 0)
        {:noreply, state}

      {:error, reason} ->
        handle_failure(state, {:rejoin_failed, reason})
    end
  end

  defp post_join(state, payload) do
    case Keyword.get(state.opts, :join_fun) do
      fun when is_function(fun, 2) ->
        fun.(state.session, payload)

      nil ->
        Client.post_json(
          state.session["coordinator"],
          "/v1/daemon-sessions",
          state.token,
          payload
        )
    end
  end

  # Exponential backoff with jitter, capped at interval * 4 (protocol
  # mandate). The jittered delay lands in [cap/2, cap] of the computed step.
  defp backoff_ms(interval_seconds, failures, opts) do
    cap_ms = interval_seconds * @backoff_cap_multiplier * 1000
    step_ms = min(interval_seconds * 1000 * Integer.pow(2, failures), cap_ms)
    half = div(step_ms, 2)
    half + jitter_fun(opts).(max(half, 1))
  end

  defp refuse_unconsented_assignments(state, data) do
    assignments = Map.get(data, "assignments", [])

    if assignments != [] and state.session["accepts_remote_work"] != true do
      Logger.warning(
        "team.policy.refused_remote_work: coordinator sent #{length(assignments)} " <>
          "assignment(s) but this daemon did not opt into remote work; refusing"
      )
    end

    :ok
  end

  # ── Liveness persistence ────────────────────────────────────────────────

  # Best-effort: liveness fields on the session file power
  # `sykli daemon status`; a write failure must never affect the loop.
  defp persist_liveness(state, fields) do
    updated =
      state.session
      |> Map.merge(fields)
      |> Map.put("last_heartbeat_at", now_fun(state.opts).())

    case session_store(state.opts).write(updated, session_store_opts(state.opts)) do
      {:ok, _} -> :ok
      _other -> :ok
    end
  end

  # ── Wiring (injectable for tests) ───────────────────────────────────────

  defp post_heartbeat(state, payload) do
    case Keyword.get(state.opts, :post_fun) do
      fun when is_function(fun, 2) ->
        fun.(state.session, payload)

      nil ->
        Client.post_json(
          state.session["coordinator"],
          "/v1/daemon-sessions/#{state.session["session_id"]}/heartbeat",
          state.token,
          payload
        )
    end
  end

  defp schedule(state, delay_ms) do
    schedule_fun =
      Keyword.get(state.opts, :schedule_fun, fn ms ->
        Process.send_after(self(), :heartbeat, ms)
      end)

    schedule_fun.(delay_ms)
  end

  defp outbox_drain(%__MODULE__{} = state) do
    Keyword.get(state.opts, :outbox_drain, fn ->
      Sykli.TeamCoordinator.OutboxDrain.drain_all(drain_opts(state))
    end)
  end

  # Drain with the loop's LIVE session (not a cwd re-read, which could miss a
  # daemon configured at a non-cwd path or pick up a stale session after rejoin)
  # and the daemon's workdir. The heartbeat's :path opt is the `.sykli` dir
  # (SessionStore convention), so the outbox workdir is its parent (#203).
  defp drain_opts(state) do
    base = [session: state.session, token: state.token]

    case Keyword.get(state.opts, :path) do
      nil -> base
      sykli_dir -> Keyword.put(base, :path, Path.dirname(sykli_dir))
    end
  end

  defp jitter_fun(opts), do: Keyword.get(opts, :jitter_fun, &:rand.uniform/1)

  defp now_fun(opts),
    do: Keyword.get(opts, :now_fun, fn -> DateTime.to_iso8601(DateTime.utc_now()) end)

  defp session_store(opts), do: Keyword.get(opts, :session_store, SessionStore)
  defp session_store_opts(opts), do: Keyword.take(opts, [:path])

  defp interval_seconds(session) do
    positive_integer(session["heartbeat_interval_seconds"], @default_interval_seconds)
  end

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback), do: fallback
end
