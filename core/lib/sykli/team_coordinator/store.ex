defmodule Sykli.TeamCoordinator.Store do
  @moduledoc """
  In-memory store for the self-hosted Team Mode coordinator skeleton.

  This store exists to make the Phase 4 API testable without adding database
  migrations in the same PR. It is not production persistence; Postgres remains
  the intended durable coordinator store in the next implementation layer.
  """

  use GenServer

  alias Sykli.TeamCoordinator.GateDecisionSummary
  alias Sykli.WorkItem

  @assignment_types WorkItem.assignment_types()
  @heartbeat_statuses ~w(available busy offline degraded draining)
  @heartbeat_interval_seconds 15
  @gate_terminal_statuses ~w(approved rejected expired)

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def create_org(server, attrs), do: GenServer.call(server, {:create_org, attrs})
  def list_orgs(server), do: GenServer.call(server, :list_orgs)
  def create_team(server, attrs), do: GenServer.call(server, {:create_team, attrs})
  def list_teams(server), do: GenServer.call(server, :list_teams)

  def resolve_team(server, org_slug, team_slug),
    do: GenServer.call(server, {:resolve_team, org_slug, team_slug})

  def create_work_item(server, attrs), do: GenServer.call(server, {:create_work_item, attrs})

  def list_work_items(server, filters \\ %{}),
    do: GenServer.call(server, {:list_work_items, filters})

  def get_work_item(server, id), do: GenServer.call(server, {:get_work_item, id})

  def claim_work_item(server, id, attrs),
    do: GenServer.call(server, {:claim_work_item, id, attrs})

  def add_note(server, id, attrs), do: GenServer.call(server, {:add_note, id, attrs})

  def create_daemon_session(server, attrs),
    do: GenServer.call(server, {:create_daemon_session, attrs})

  def list_daemon_sessions(server, filters \\ %{}),
    do: GenServer.call(server, {:list_daemon_sessions, filters})

  def get_daemon_session(server, id), do: GenServer.call(server, {:get_daemon_session, id})

  def heartbeat_daemon_session(server, id, attrs),
    do: GenServer.call(server, {:heartbeat_daemon_session, id, attrs})

  def record_run(server, payload), do: GenServer.call(server, {:record_run, payload})
  def get_run(server, id), do: GenServer.call(server, {:get_run, id})
  def list_runs(server, filters \\ %{}), do: GenServer.call(server, {:list_runs, filters})
  def upsert_gate(server, payload), do: GenServer.call(server, {:upsert_gate, payload})

  def record_gate_decision(server, id, attrs),
    do: GenServer.call(server, {:record_gate_decision, id, attrs})

  def get_gate(server, id), do: GenServer.call(server, {:get_gate, id})
  def list_gates(server, filters \\ %{}), do: GenServer.call(server, {:list_gates, filters})

  def audit_log(server), do: GenServer.call(server, :audit_log)

  @impl true
  def init(opts) do
    {:ok,
     %{
       now: Keyword.get(opts, :now, &DateTime.utc_now/0),
       id: Keyword.get(opts, :id, &Sykli.ULID.generate/0),
       # Sessions silent past this many seconds are dead per the protocol's
       # resume cutoff; the sweep removes them and their delivery queues.
       session_expiry_seconds: Keyword.get(opts, :session_expiry_seconds, 300),
       orgs: %{},
       orgs_by_slug: %{},
       teams: %{},
       teams_by_org_slug: %{},
       work_items: %{},
       notes_by_work_item: %{},
       daemon_sessions: %{},
       daemon_sessions_by_identity: %{},
       runs: %{},
       gates: %{},
       pending_gate_decisions: %{},
       audit_log: []
     }}
  end

  @impl true
  def handle_call({:create_org, attrs}, _from, state) do
    with {:ok, slug} <- required_slug(attrs, "slug"),
         {:ok, name} <- required_string(attrs, "name"),
         :ok <- ensure_absent(state.orgs_by_slug, slug, {:duplicate_org_slug, slug}) do
      org = %{
        "id" => id(state),
        "slug" => slug,
        "name" => name,
        "created_at" => now(state)
      }

      state =
        state
        |> put_in([:orgs, org["id"]], org)
        |> put_in([:orgs_by_slug, slug], org["id"])
        |> audit("org.created", "org", org["id"], org["id"], nil)

      {:reply, {:ok, org}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_orgs, _from, state) do
    {:reply, {:ok, sorted_values(state.orgs)}, state}
  end

  def handle_call({:create_team, attrs}, _from, state) do
    with {:ok, org_id} <- org_id(state, attrs),
         {:ok, slug} <- required_slug(attrs, "slug"),
         {:ok, name} <- required_string(attrs, "name"),
         :ok <-
           ensure_absent(state.teams_by_org_slug, {org_id, slug}, {:duplicate_team_slug, slug}) do
      team = %{
        "id" => id(state),
        "org_id" => org_id,
        "slug" => slug,
        "name" => name,
        "created_at" => now(state)
      }

      state =
        state
        |> put_in([:teams, team["id"]], team)
        |> put_in([:teams_by_org_slug, {org_id, slug}], team["id"])
        |> audit("team.created", "team", team["id"], org_id, team["id"])

      {:reply, {:ok, team}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_teams, _from, state) do
    {:reply, {:ok, sorted_values(state.teams)}, state}
  end

  def handle_call({:resolve_team, org_slug, team_slug}, _from, state) do
    result =
      with {:ok, org_id} <- org_id(state, %{"org_slug" => org_slug}),
           {:ok, team_id} <- team_id(state, %{"team_slug" => team_slug}, org_id) do
        {:ok,
         %{
           "org_id" => org_id,
           "team_id" => team_id,
           "org_slug" => org_slug,
           "team_slug" => team_slug
         }}
      end

    {:reply, result, state}
  end

  def handle_call({:create_work_item, attrs}, _from, state) do
    with {:ok, org_id} <- org_id(state, attrs),
         {:ok, team_id} <- team_id(state, attrs, org_id),
         {:ok, title} <- required_string(attrs, "title") do
      now = now(state)

      item = %{
        "id" => id(state),
        "org_id" => org_id,
        "team_id" => team_id,
        "title" => title,
        "intent" => blank_to_nil(Map.get(attrs, "intent")),
        "status" => "open",
        "created_by" => blank_to_nil(Map.get(attrs, "created_by")),
        "assigned_to_type" => nil,
        "assigned_to_id" => nil,
        "created_at" => now,
        "updated_at" => now
      }

      state =
        state
        |> put_in([:work_items, item["id"]], item)
        |> put_in([:notes_by_work_item, item["id"]], [])
        |> audit("work.created", "work_item", item["id"], org_id, team_id)

      {:reply, {:ok, item}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_work_items, filters}, _from, state) do
    items =
      state.work_items
      |> sorted_values()
      |> Enum.filter(fn item ->
        filter_match?(item, "org_id", Map.get(filters, "org_id")) and
          filter_match?(item, "team_id", Map.get(filters, "team_id"))
      end)

    {:reply, {:ok, items}, state}
  end

  def handle_call({:get_work_item, id}, _from, state) do
    {:reply, fetch_work_item(state, id), state}
  end

  def handle_call({:claim_work_item, id, attrs}, _from, state) do
    with {:ok, item} <- fetch_work_item(state, id),
         :ok <- ensure_claimable(item),
         {:ok, assignment_type} <- required_assignment_type(attrs),
         {:ok, assignment_id} <- required_string(attrs, "assigned_to_id") do
      now = now(state)

      updated =
        item
        |> Map.put("status", "claimed")
        |> Map.put("assigned_to_type", assignment_type)
        |> Map.put("assigned_to_id", assignment_id)
        |> Map.put("updated_at", now)

      state =
        state
        |> put_in([:work_items, id], updated)
        |> audit("work.claimed", "work_item", id, item["org_id"], item["team_id"])

      {:reply, {:ok, updated}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:add_note, id, attrs}, _from, state) do
    with {:ok, item} <- fetch_work_item(state, id),
         {:ok, body} <- required_string(attrs, "body") do
      note = %{
        "id" => id(state),
        "work_item_id" => id,
        "author_type" => blank_to_nil(Map.get(attrs, "author_type")),
        "author_id" => blank_to_nil(Map.get(attrs, "author_id")),
        "body" => body,
        "created_at" => now(state)
      }

      notes = Map.get(state.notes_by_work_item, id, []) ++ [note]
      updated = Map.put(item, "updated_at", note["created_at"])

      state =
        state
        |> put_in([:notes_by_work_item, id], notes)
        |> put_in([:work_items, id], updated)
        |> audit("work.note_added", "work_item", id, item["org_id"], item["team_id"])

      {:reply, {:ok, note}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:create_daemon_session, attrs}, _from, state) do
    with {:ok, org_id} <- org_id_from_join(state, attrs),
         {:ok, team_id} <- team_id_from_join(state, attrs, org_id),
         {:ok, daemon_id} <- required_daemon_id(attrs),
         {:ok, labels} <- optional_string_list(attrs, "labels"),
         {:ok, capabilities} <- optional_string_list(attrs, "capabilities"),
         {:ok, version} <- required_string(attrs, "version"),
         {:ok, accepts_remote_work} <- optional_boolean(attrs, "accepts_remote_work", false) do
      now = now(state)
      session_id = id(state)
      identity = {org_id, team_id, daemon_id}

      session = %{
        "id" => session_id,
        "session_id" => session_id,
        "org_id" => org_id,
        "team_id" => team_id,
        "daemon_id" => daemon_id,
        "display_name" => blank_to_nil(Map.get(attrs, "display_name")) || daemon_id,
        "status" => "available",
        "labels" => labels,
        "capabilities" => capabilities,
        "version" => version,
        "accepts_remote_work" => accepts_remote_work,
        "current_work_item_id" => nil,
        "last_run_id" => nil,
        "last_seen_at" => now,
        "created_at" => now,
        "updated_at" => now,
        "superseded_by" => nil
      }

      state =
        state
        |> prune_stale_sessions()
        |> supersede_existing_daemon(identity, session_id, now)
        |> put_in([:daemon_sessions, session_id], session)
        |> put_in([:daemon_sessions_by_identity, identity], session_id)
        |> reenqueue_undelivered_decisions(identity, session_id)
        |> audit("daemon.joined", "daemon_session", session_id, org_id, team_id)

      {:reply, {:ok, session_response(session), session}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_daemon_sessions, filters}, _from, state) do
    sessions =
      state.daemon_sessions
      |> sorted_values()
      |> Enum.filter(fn session ->
        filter_match?(session, "org_id", Map.get(filters, "org_id")) and
          filter_match?(session, "team_id", Map.get(filters, "team_id"))
      end)

    {:reply, {:ok, sessions}, state}
  end

  def handle_call({:get_daemon_session, id}, _from, state) do
    {:reply, fetch_daemon_session(state, id), state}
  end

  def handle_call({:heartbeat_daemon_session, id, attrs}, _from, state) do
    state = prune_stale_sessions(state)

    with {:ok, session} <- fetch_daemon_session(state, id),
         :ok <- validate_session_id_match(id, Map.get(attrs, "session_id")),
         {:ok, status} <- required_heartbeat_status(attrs),
         {:ok, acknowledged_ids} <- optional_string_list(attrs, "acknowledged_decision_ids", []),
         {:ok, labels} <- optional_string_list(attrs, "labels", session["labels"]),
         {:ok, capabilities} <-
           optional_string_list(attrs, "capabilities", session["capabilities"]) do
      now = now(state)

      updated =
        session
        |> Map.put("status", status)
        |> Map.put("labels", labels)
        |> Map.put("capabilities", capabilities)
        |> Map.put("current_work_item_id", blank_to_nil(Map.get(attrs, "current_work_item_id")))
        |> Map.put("last_run_id", blank_to_nil(Map.get(attrs, "last_run_id")))
        |> Map.put("last_seen_at", now)
        |> Map.put("updated_at", now)

      state =
        state
        |> acknowledge_gate_decisions(id, acknowledged_ids, now)
        |> put_in([:daemon_sessions, id], updated)
        |> audit("daemon.heartbeat", "daemon_session", id, session["org_id"], session["team_id"])

      decisions = Map.get(state.pending_gate_decisions, id, [])

      heartbeat = %{
        "next_heartbeat_seconds" => @heartbeat_interval_seconds,
        "decisions" => decisions,
        "assignments" => []
      }

      {:reply, {:ok, heartbeat, updated}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_run, payload}, _from, state) do
    with {:ok, record} <- build_run_record(state, payload) do
      run_id = record["run"]["id"]

      case Map.fetch(state.runs, run_id) do
        {:ok, stored} ->
          {:reply, {:ok, stored, :existing}, state}

        :error ->
          state =
            state
            |> put_in([:runs, run_id], record)
            |> audit_run_recorded(record)

          {:reply, {:ok, record, :inserted}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_run, id}, _from, state) do
    {:reply, fetch_run(state, id), state}
  end

  def handle_call({:list_runs, filters}, _from, state) do
    runs =
      state.runs
      |> sorted_values()
      |> Enum.filter(fn record ->
        run = record["run"]

        filter_match?(run, "org_id", Map.get(filters, "org_id")) and
          filter_match?(run, "team_id", Map.get(filters, "team_id")) and
          filter_match?(run, "work_item_id", Map.get(filters, "work_item_id")) and
          filter_match?(run, "status", Map.get(filters, "status"))
      end)
      |> Enum.map(& &1["run"])

    {:reply, {:ok, runs}, state}
  end

  def handle_call({:upsert_gate, payload}, _from, state) do
    with {:ok, record} <- build_gate_record(state, payload) do
      gate_id = record["id"]

      case Map.fetch(state.gates, gate_id) do
        {:ok, stored} ->
          {:reply, {:ok, stored, :existing}, state}

        :error ->
          state =
            state
            |> put_in([:gates, gate_id], record)
            |> audit_gate_requested(record)

          {:reply, {:ok, record, :inserted}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_gate_decision, id, attrs}, _from, state) do
    with {:ok, gate} <- fetch_gate(state, id),
         :ok <- validate_gate_team_claim(state, gate, attrs),
         :ok <- ensure_gate_decidable(gate),
         {:ok, decision} <- build_gate_decision(attrs, state) do
      updated =
        gate
        |> Map.merge(decision)
        |> Map.put("updated_at", now(state))

      state =
        state
        |> put_in([:gates, id], updated)
        |> enqueue_gate_decision(updated)
        |> audit_gate_decision_recorded(updated)

      {:reply, {:ok, updated}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_gate, id}, _from, state) do
    {:reply, fetch_gate(state, id), state}
  end

  def handle_call({:list_gates, filters}, _from, state) do
    with {:ok, filters} <- gate_filters(state, filters) do
      gates =
        state.gates
        |> sorted_values()
        |> Enum.filter(fn gate ->
          filter_match?(gate, "org_id", Map.get(filters, "org_id")) and
            filter_match?(gate, "team_id", Map.get(filters, "team_id")) and
            filter_match?(gate, "status", Map.get(filters, "status"))
        end)
        |> Enum.map(&gate_public_map/1)

      {:reply, {:ok, gates}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:audit_log, _from, state) do
    {:reply, {:ok, Enum.reverse(state.audit_log)}, state}
  end

  defp org_id_from_join(state, attrs) do
    org_id(state, Map.put_new(attrs, "org_slug", Map.get(attrs, "org")))
  end

  defp team_id_from_join(state, attrs, org_id) do
    team_id(state, Map.put_new(attrs, "team_slug", Map.get(attrs, "team")), org_id)
  end

  defp required_slug(attrs, field) do
    with {:ok, value} <- required_string(attrs, field) do
      if Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,62}$/, value) do
        {:ok, value}
      else
        {:error, {:invalid_field, field}}
      end
    end
  end

  defp required_string(attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, {:missing_field, field}}, else: {:ok, trimmed}

      _ ->
        {:error, {:missing_field, field}}
    end
  end

  defp required_daemon_id(attrs) do
    with {:ok, daemon_id} <- required_string(attrs, "daemon_id") do
      if Regex.match?(~r/^[a-z0-9._-]{1,128}$/, daemon_id) do
        {:ok, daemon_id}
      else
        {:error, {:invalid_daemon_id, daemon_id}}
      end
    end
  end

  defp optional_string_list(attrs, field, default \\ []) do
    case Map.get(attrs, field, default) do
      values when is_list(values) ->
        values
        |> Enum.reduce_while({:ok, []}, fn
          value, {:ok, acc} when is_binary(value) ->
            value = String.trim(value)

            cond do
              value == "" -> {:halt, {:error, {:invalid_daemon_list_field, field}}}
              String.length(value) > 128 -> {:halt, {:error, {:invalid_daemon_list_field, field}}}
              true -> {:cont, {:ok, [value | acc]}}
            end

          _value, _acc ->
            {:halt, {:error, {:invalid_daemon_list_field, field}}}
        end)
        |> case do
          {:ok, values} -> {:ok, Enum.reverse(values)}
          error -> error
        end

      _other ->
        {:error, {:invalid_daemon_list_field, field}}
    end
  end

  defp optional_boolean(attrs, field, default) do
    case Map.get(attrs, field, default) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, field}}
    end
  end

  defp org_id(state, attrs) do
    cond do
      is_binary(Map.get(attrs, "org_id")) and Map.has_key?(state.orgs, Map.get(attrs, "org_id")) ->
        {:ok, Map.get(attrs, "org_id")}

      is_binary(Map.get(attrs, "org_slug")) ->
        case Map.fetch(state.orgs_by_slug, Map.get(attrs, "org_slug")) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, {:org_not_found, Map.get(attrs, "org_slug")}}
        end

      true ->
        {:error, {:org_not_found, Map.get(attrs, "org_id") || Map.get(attrs, "org_slug")}}
    end
  end

  defp team_id(state, attrs, org_id) do
    cond do
      is_binary(Map.get(attrs, "team_id")) and
          match?(%{"org_id" => ^org_id}, Map.get(state.teams, Map.get(attrs, "team_id"))) ->
        {:ok, Map.get(attrs, "team_id")}

      is_binary(Map.get(attrs, "team_slug")) ->
        case Map.fetch(state.teams_by_org_slug, {org_id, Map.get(attrs, "team_slug")}) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, {:team_not_found, Map.get(attrs, "team_slug")}}
        end

      true ->
        {:error, {:team_not_found, Map.get(attrs, "team_id") || Map.get(attrs, "team_slug")}}
    end
  end

  defp required_assignment_type(attrs) do
    case Map.get(attrs, "assigned_to_type") || Map.get(attrs, "assignee_type") do
      type when type in @assignment_types -> {:ok, type}
      type -> {:error, {:invalid_assignment_type, type}}
    end
  end

  defp required_heartbeat_status(attrs) do
    case Map.get(attrs, "status") do
      status when status in @heartbeat_statuses -> {:ok, status}
      status -> {:error, {:invalid_daemon_status, status}}
    end
  end

  defp validate_session_id_match(_id, nil), do: :ok
  defp validate_session_id_match(id, id), do: :ok
  defp validate_session_id_match(_id, value), do: {:error, {:invalid_daemon_session_id, value}}

  defp gate_filters(state, filters) do
    with {:ok, org_id} <- optional_org_id(state, filters),
         {:ok, team_id} <- optional_team_id(state, filters, org_id) do
      {:ok,
       filters
       |> Map.put("org_id", org_id)
       |> Map.put("team_id", team_id)}
    end
  end

  defp optional_org_id(_state, %{"org_id" => org_id}) when is_binary(org_id) and org_id != "",
    do: {:ok, org_id}

  defp optional_org_id(state, %{"org_slug" => slug}) when is_binary(slug) and slug != "",
    do: org_id(state, %{"org_slug" => slug})

  defp optional_org_id(_state, _filters), do: {:ok, nil}

  defp optional_team_id(_state, %{"team_id" => team_id}, _org_id)
       when is_binary(team_id) and team_id != "",
       do: {:ok, team_id}

  defp optional_team_id(state, %{"team_slug" => slug}, org_id)
       when is_binary(slug) and slug != "" and is_binary(org_id),
       do: team_id(state, %{"team_slug" => slug}, org_id)

  defp optional_team_id(_state, %{"team_slug" => slug}, nil)
       when is_binary(slug) and slug != "",
       do: {:error, {:org_not_found, nil}}

  defp optional_team_id(_state, _filters, _org_id), do: {:ok, nil}

  defp build_gate_record(state, payload) do
    with :ok <- validate_exact_keys(payload, gate_publish_fields()),
         {:ok, org_id} <- org_id(state, payload),
         {:ok, team_id} <- team_id(state, payload, org_id),
         {:ok, daemon_session_id} <- required_string(payload, "daemon_session_id"),
         {:ok, session} <- fetch_gate_daemon_session(state, daemon_session_id),
         :ok <- validate_session_team(session, team_id),
         {:ok, summary} <- GateDecisionSummary.from_map(Map.take(payload, gate_payload_fields())),
         :ok <- validate_waiting_gate(summary.gate["status"]) do
      now = now(state)

      {:ok,
       summary.gate
       |> Map.put("org_id", org_id)
       |> Map.put("team_id", team_id)
       |> Map.put("daemon_session_id", daemon_session_id)
       |> Map.put("daemon_id", session["daemon_id"])
       |> Map.put("created_at", now)
       |> Map.put("updated_at", now)}
    end
  end

  defp fetch_gate_daemon_session(state, id) do
    case fetch_daemon_session(state, id) do
      {:ok, session} -> {:ok, session}
      {:error, {:daemon_session_not_found, _id}} -> {:error, :team_gate_unknown_session}
      {:error, {:invalid_daemon_session_id, _id}} -> {:error, :team_gate_unknown_session}
    end
  end

  defp validate_session_team(%{"team_id" => team_id}, team_id) when is_binary(team_id), do: :ok

  defp validate_session_team(%{"team_id" => session_team}, _team_id)
       when is_binary(session_team) and session_team != "",
       do: {:error, :team_gate_team_mismatch}

  # A session record without usable team metadata is coordinator-side data
  # corruption, not an authorization failure — report it as such (#202).
  defp validate_session_team(_session, _team_id), do: {:error, :team_gate_invalid_session}

  defp validate_waiting_gate("waiting"), do: :ok
  defp validate_waiting_gate(_status), do: {:error, :team_gate_invalid_payload}

  defp validate_gate_team_claim(state, gate, attrs) do
    with {:ok, org_id} <- org_id(state, attrs),
         {:ok, team_id} <- team_id(state, attrs, org_id) do
      if gate["team_id"] == team_id do
        :ok
      else
        {:error, :team_gate_team_mismatch}
      end
    end
  end

  defp build_gate_decision(attrs, state) do
    with :ok <-
           validate_exact_keys(attrs, ~w(org_slug team_slug status decided_by decided_at reason)),
         {:ok, status} <- required_gate_decision_status(attrs),
         {:ok, decided_by} <- required_string(attrs, "decided_by"),
         {:ok, reason} <- required_string(attrs, "reason") do
      {:ok,
       %{
         "status" => status,
         "decided_by" => decided_by,
         "decided_at" => blank_to_nil(attrs["decided_at"]) || now(state),
         "reason" => reason
       }}
    end
  end

  defp required_gate_decision_status(attrs) do
    case Map.get(attrs, "status") do
      status when status in ~w(approved rejected) -> {:ok, status}
      _ -> {:error, :team_gate_invalid_decision}
    end
  end

  defp ensure_gate_decidable(%{"status" => status}) when status in ["waiting", "blocked"], do: :ok

  defp ensure_gate_decidable(%{"status" => status}) when status in @gate_terminal_statuses,
    do: {:error, {:team_gate_terminal, status}}

  defp ensure_gate_decidable(_gate), do: {:error, :team_gate_invalid_decision}

  defp enqueue_gate_decision(state, gate) do
    payload = gate_public_map(gate)
    session_id = gate["daemon_session_id"]

    update_in(state, [:pending_gate_decisions, session_id], fn
      nil -> [payload]
      decisions -> replace_decision(decisions, payload)
    end)
  end

  defp replace_decision(decisions, payload) do
    decisions
    |> Enum.reject(&(&1["id"] == payload["id"]))
    |> Kernel.++([payload])
  end

  defp acknowledge_gate_decisions(state, _session_id, [], _now), do: state

  defp acknowledge_gate_decisions(state, session_id, ids, now) do
    state
    |> update_in([:pending_gate_decisions, session_id], fn
      nil -> []
      decisions -> Enum.reject(decisions, &(&1["id"] in ids))
    end)
    |> stamp_acknowledged_gates(ids, now)
  end

  # Delivery state lives on the gate record, not only in the per-session
  # queue — queues are a disposable delivery cache (#205); an unacknowledged
  # decision can always be re-enqueued from the gate on rejoin.
  defp stamp_acknowledged_gates(state, ids, now) do
    Enum.reduce(ids, state, fn id, acc ->
      case acc.gates[id] do
        nil -> acc
        gate -> put_in(acc, [:gates, id], Map.put(gate, "acknowledged_at", now))
      end
    end)
  end

  defp gate_payload_fields do
    ~w(id run_id node_id work_item_id status decided_by decided_at reason)
  end

  defp gate_publish_fields do
    ~w(org_slug team_slug daemon_session_id id run_id node_id work_item_id status decided_by decided_at reason)
  end

  defp gate_public_map(gate), do: Map.take(gate, gate_payload_fields())

  defp validate_exact_keys(map, allowed) do
    extra = Map.keys(map) -- allowed
    if extra == [], do: :ok, else: {:error, :team_gate_invalid_payload}
  end

  defp build_run_record(state, %{"version" => "1", "run" => run} = payload) when is_map(run) do
    with {:ok, org_id} <- org_id(state, run),
         {:ok, team_id} <- team_id(state, run, org_id),
         {:ok, run_id} <- required_string(run, "id"),
         {:ok, status} <- required_run_status(run),
         :ok <- validate_list(payload, "nodes"),
         :ok <- validate_list(payload, "criteria_results"),
         :ok <- validate_list(payload, "review_results"),
         :ok <- validate_list(payload, "gates"),
         :ok <- validate_list(payload, "evidence_refs") do
      stored_run =
        run
        |> Map.put("id", run_id)
        |> Map.put("org_id", org_id)
        |> Map.put("team_id", team_id)
        |> Map.put("status", status)

      {:ok,
       %{
         "id" => run_id,
         "run" => stored_run,
         "nodes" => Map.get(payload, "nodes", []),
         "criteria_results" => Map.get(payload, "criteria_results", []),
         "review_results" => Map.get(payload, "review_results", []),
         "gates" => Map.get(payload, "gates", []),
         "evidence_refs" => Map.get(payload, "evidence_refs", [])
       }}
    end
  end

  defp build_run_record(_state, _payload), do: {:error, :team_run_invalid_payload}

  defp required_run_status(attrs) do
    case Map.get(attrs, "status") do
      status when status in ~w(passed failed) -> {:ok, status}
      _ -> {:error, :team_run_invalid_payload}
    end
  end

  defp validate_list(payload, field) do
    if is_list(Map.get(payload, field, [])), do: :ok, else: {:error, :team_run_invalid_payload}
  end

  defp fetch_work_item(state, id) do
    with :ok <- WorkItem.validate_id(id) do
      case Map.fetch(state.work_items, id) do
        {:ok, item} -> {:ok, item}
        :error -> {:error, {:work_item_not_found, id}}
      end
    end
  end

  defp fetch_daemon_session(state, id) when is_binary(id) and id not in ["", ".", ".."] do
    if String.contains?(id, ["/", "\\", <<0>>]) do
      {:error, {:invalid_daemon_session_id, id}}
    else
      case Map.fetch(state.daemon_sessions, id) do
        {:ok, session} -> {:ok, session}
        :error -> {:error, {:daemon_session_not_found, id}}
      end
    end
  end

  defp fetch_daemon_session(_state, id), do: {:error, {:invalid_daemon_session_id, id}}

  defp fetch_run(state, id) when is_binary(id) and id not in ["", ".", ".."] do
    if String.contains?(id, ["/", "\\", <<0>>]) do
      {:error, {:invalid_run_id, id}}
    else
      case Map.fetch(state.runs, id) do
        {:ok, run} -> {:ok, run}
        :error -> {:error, :run_not_found}
      end
    end
  end

  defp fetch_run(_state, id), do: {:error, {:invalid_run_id, id}}

  defp fetch_gate(state, id) when is_binary(id) and id not in ["", ".", ".."] do
    with :ok <- Sykli.GateDecision.validate_id(id) do
      case Map.fetch(state.gates, id) do
        {:ok, gate} -> {:ok, gate}
        :error -> {:error, {:gate_not_found, id}}
      end
    end
  end

  defp fetch_gate(_state, id), do: {:error, {:invalid_gate_id, id}}

  defp supersede_existing_daemon(state, identity, new_session_id, now) do
    case Map.fetch(state.daemon_sessions_by_identity, identity) do
      {:ok, old_session_id} ->
        state
        |> update_in([:daemon_sessions, old_session_id], fn
          nil ->
            nil

          session ->
            session
            |> Map.put("status", "offline")
            |> Map.put("superseded_by", new_session_id)
            |> Map.put("updated_at", now)
        end)
        |> move_pending_gate_decisions(old_session_id, new_session_id)

      :error ->
        state
    end
  end

  defp move_pending_gate_decisions(state, old_session_id, new_session_id) do
    case Map.pop(state.pending_gate_decisions, old_session_id) do
      {nil, pending} ->
        %{state | pending_gate_decisions: pending}

      {decisions, pending} ->
        merged =
          Enum.reduce(decisions, Map.get(pending, new_session_id, []), fn decision, acc ->
            replace_decision(acc, decision)
          end)

        %{state | pending_gate_decisions: Map.put(pending, new_session_id, merged)}
    end
  end

  # Recovery path for #205: a rejoin after the previous session (and its
  # queue) was pruned must still receive decided-but-unacknowledged gates.
  # The gate record is the source of truth; the queue is rebuilt from it
  # and the gate is retargeted to the new session. replace_decision/2
  # dedups against anything the supersede fast path already moved.
  defp reenqueue_undelivered_decisions(state, {org_id, team_id, daemon_id}, new_session_id) do
    state.gates
    |> Map.values()
    |> Enum.filter(fn gate ->
      gate["org_id"] == org_id and gate["team_id"] == team_id and
        gate["daemon_id"] == daemon_id and gate["status"] != "waiting" and
        is_nil(gate["acknowledged_at"])
    end)
    |> Enum.reduce(state, fn gate, acc ->
      retargeted = Map.put(gate, "daemon_session_id", new_session_id)

      acc
      |> put_in([:gates, gate["id"]], retargeted)
      |> enqueue_gate_decision(retargeted)
    end)
  end

  # Retention sweep for #205: sessions whose last heartbeat is older than
  # the expiry are dead per the protocol's resume cutoff — remove the
  # session, its delivery queue, and its identity mapping. Runs
  # opportunistically on join and heartbeat (the in-memory skeleton has no
  # timers). Unacknowledged decisions survive on the gate records and are
  # re-enqueued if the daemon ever rejoins.
  defp prune_stale_sessions(state) do
    case DateTime.from_iso8601(now(state)) do
      {:ok, now_dt, _offset} ->
        cutoff = DateTime.add(now_dt, -state.session_expiry_seconds, :second)

        stale_ids =
          state.daemon_sessions
          |> Enum.filter(fn {_id, session} -> session_stale?(session, cutoff) end)
          |> Enum.map(fn {id, _session} -> id end)
          |> MapSet.new()

        if MapSet.size(stale_ids) == 0 do
          state
        else
          %{
            state
            | daemon_sessions: Map.drop(state.daemon_sessions, MapSet.to_list(stale_ids)),
              pending_gate_decisions:
                Map.drop(state.pending_gate_decisions, MapSet.to_list(stale_ids)),
              daemon_sessions_by_identity:
                state.daemon_sessions_by_identity
                |> Enum.reject(fn {_identity, id} -> MapSet.member?(stale_ids, id) end)
                |> Map.new()
          }
        end

      _other ->
        state
    end
  end

  defp session_stale?(session, cutoff) do
    case DateTime.from_iso8601(session["last_seen_at"] || "") do
      {:ok, last_seen, _offset} -> DateTime.compare(last_seen, cutoff) == :lt
      _other -> false
    end
  end

  defp session_response(session) do
    %{
      "session_id" => session["session_id"],
      "heartbeat_interval_seconds" => @heartbeat_interval_seconds,
      "team_id" => session["team_id"],
      "policy" => %{
        "sync_run_summaries" => true,
        "sync_evidence_refs" => true,
        "upload_raw_logs_by_default" => false
      }
    }
  end

  defp ensure_claimable(%{"status" => "open"}), do: :ok

  defp ensure_claimable(item) do
    {:error,
     {:work_item_already_claimed, item["id"],
      %{
        "status" => item["status"],
        "assigned_to_type" => item["assigned_to_type"],
        "assigned_to_id" => item["assigned_to_id"]
      }}}
  end

  defp ensure_absent(map, key, reason) do
    if Map.has_key?(map, key), do: {:error, reason}, else: :ok
  end

  defp sorted_values(map) do
    map
    |> Map.values()
    |> Enum.sort_by(& &1["id"])
  end

  defp filter_match?(_item, _field, nil), do: true
  defp filter_match?(item, field, value), do: item[field] == value

  defp audit(state, action, subject_type, subject_id, org_id, team_id) do
    event = %{
      "id" => id(state),
      "org_id" => org_id,
      "team_id" => team_id,
      "actor_type" => "system",
      "actor_id" => "coordinator",
      "action" => action,
      "subject_type" => subject_type,
      "subject_id" => subject_id,
      "metadata" => %{},
      "created_at" => now(state)
    }

    update_in(state.audit_log, &[event | &1])
  end

  defp audit_run_recorded(state, record) do
    run = record["run"]

    event = %{
      "id" => id(state),
      "org_id" => run["org_id"],
      "team_id" => run["team_id"],
      "actor_type" => "system",
      "actor_id" => "coordinator",
      "action" => "run.recorded",
      "subject_type" => "run",
      "subject_id" => run["id"],
      "metadata" => %{"event" => "run_recorded", "status" => run["status"]},
      "created_at" => now(state)
    }

    update_in(state.audit_log, &[event | &1])
  end

  defp audit_gate_requested(state, gate) do
    event = %{
      "id" => id(state),
      "org_id" => gate["org_id"],
      "team_id" => gate["team_id"],
      "actor_type" => "daemon_session",
      "actor_id" => gate["daemon_session_id"],
      "action" => "gate.requested",
      "subject_type" => "gate",
      "subject_id" => gate["id"],
      "metadata" => %{"status" => gate["status"]},
      "created_at" => now(state)
    }

    update_in(state.audit_log, &[event | &1])
  end

  defp audit_gate_decision_recorded(state, gate) do
    event = %{
      "id" => id(state),
      "org_id" => gate["org_id"],
      "team_id" => gate["team_id"],
      "actor_type" => "member",
      "actor_id" => gate["decided_by"],
      "action" => "gate.decision_recorded",
      "subject_type" => "gate",
      "subject_id" => gate["id"],
      "metadata" => %{"status" => gate["status"], "reason" => gate["reason"]},
      "created_at" => now(state)
    }

    update_in(state.audit_log, &[event | &1])
  end

  defp id(state), do: state.id.()

  defp now(state) do
    state.now.()
    |> case do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      value when is_binary(value) -> value
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil
end
