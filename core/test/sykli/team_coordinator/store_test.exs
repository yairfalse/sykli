defmodule Sykli.TeamCoordinator.StoreTest do
  use ExUnit.Case, async: true

  alias Sykli.TeamCoordinator.Store

  @now "2026-05-09T10:00:00Z"

  setup do
    {:ok, store} =
      Store.start_link(
        now: fn -> @now end,
        id:
          id_sequence(
            ~w(org_001 audit_001 team_001 audit_002 work_001 audit_003 audit_004 note_001 audit_005)
          )
      )

    {:ok, store: store}
  end

  test "creates orgs and rejects duplicate slugs", %{store: store} do
    assert {:ok, org} =
             Store.create_org(store, %{"slug" => "false-systems", "name" => "False Systems"})

    assert org["id"] == "org_001"
    assert org["created_at"] == @now

    assert {:error, {:duplicate_org_slug, "false-systems"}} =
             Store.create_org(store, %{"slug" => "false-systems", "name" => "Duplicate"})
  end

  test "creates teams under orgs and rejects missing or duplicate teams", %{store: store} do
    assert {:error, {:org_not_found, "missing"}} =
             Store.create_team(store, %{
               "org_slug" => "missing",
               "slug" => "platform",
               "name" => "Platform"
             })

    assert {:ok, org} =
             Store.create_org(store, %{"slug" => "false-systems", "name" => "False Systems"})

    assert {:ok, team} =
             Store.create_team(store, %{
               "org_id" => org["id"],
               "slug" => "platform",
               "name" => "Platform"
             })

    assert team["id"] == "team_001"
    assert team["org_id"] == org["id"]

    assert {:error, {:duplicate_team_slug, "platform"}} =
             Store.create_team(store, %{
               "org_id" => org["id"],
               "slug" => "platform",
               "name" => "Again"
             })
  end

  test "creates lists shows claims and notes work items", %{store: store} do
    {:ok, org} = Store.create_org(store, %{"slug" => "false-systems", "name" => "False Systems"})

    {:ok, team} =
      Store.create_team(store, %{
        "org_id" => org["id"],
        "slug" => "platform",
        "name" => "Platform"
      })

    assert {:ok, item} =
             Store.create_work_item(store, %{
               "org_id" => org["id"],
               "team_id" => team["id"],
               "title" => "Investigate deploy",
               "intent" => "Find the failing step"
             })

    assert item["id"] == "work_001"
    assert item["status"] == "open"
    refute Map.has_key?(item, "logs")
    refute Map.has_key?(item, "artifacts")
    refute Map.has_key?(item, "secrets")

    assert {:ok, [^item]} = Store.list_work_items(store)
    assert {:ok, ^item} = Store.get_work_item(store, item["id"])

    assert {:ok, claimed} =
             Store.claim_work_item(store, item["id"], %{
               "assigned_to_type" => "member",
               "assigned_to_id" => "yair"
             })

    assert claimed["status"] == "claimed"
    assert claimed["assigned_to_type"] == "member"
    assert claimed["assigned_to_id"] == "yair"

    assert {:error, {:work_item_already_claimed, "work_001", _assignment}} =
             Store.claim_work_item(store, item["id"], %{
               "assigned_to_type" => "agent",
               "assigned_to_id" => "claude"
             })

    assert {:ok, note} =
             Store.add_note(store, item["id"], %{
               "author_type" => "member",
               "author_id" => "yair",
               "body" => "Found likely API breakage"
             })

    assert note["work_item_id"] == item["id"]
    assert note["body"] == "Found likely API breakage"
  end

  test "validates work payloads", %{store: store} do
    assert {:error, {:org_not_found, nil}} =
             Store.create_work_item(store, %{"title" => "No team"})

    {:ok, org} = Store.create_org(store, %{"slug" => "false-systems", "name" => "False Systems"})

    {:ok, team} =
      Store.create_team(store, %{
        "org_id" => org["id"],
        "slug" => "platform",
        "name" => "Platform"
      })

    {:ok, item} =
      Store.create_work_item(store, %{
        "org_id" => org["id"],
        "team_id" => team["id"],
        "title" => "Task"
      })

    assert {:error, {:invalid_assignment_type, "robot"}} =
             Store.claim_work_item(store, item["id"], %{
               "assigned_to_type" => "robot",
               "assigned_to_id" => "r2d2"
             })

    assert {:error, {:missing_field, "body"}} = Store.add_note(store, item["id"], %{"body" => ""})

    assert {:error, {:invalid_work_item_id, "../escape"}} =
             Store.get_work_item(store, "../escape")

    assert {:error, {:work_item_not_found, "missing"}} = Store.get_work_item(store, "missing")
  end

  test "writes audit events for state-changing calls", %{store: store} do
    {:ok, org} = Store.create_org(store, %{"slug" => "false-systems", "name" => "False Systems"})

    {:ok, team} =
      Store.create_team(store, %{
        "org_id" => org["id"],
        "slug" => "platform",
        "name" => "Platform"
      })

    {:ok, item} =
      Store.create_work_item(store, %{
        "org_id" => org["id"],
        "team_id" => team["id"],
        "title" => "Task"
      })

    assert {:ok, events} = Store.audit_log(store)
    assert Enum.map(events, & &1["action"]) == ["org.created", "team.created", "work.created"]
    assert Enum.all?(events, &(&1["actor_type"] == "system"))
    assert List.last(events)["subject_id"] == item["id"]
  end

  test "records runs idempotently and filters run list", %{store: store} do
    {:ok, org} = Store.create_org(store, %{"slug" => "false-systems", "name" => "False Systems"})

    {:ok, team} =
      Store.create_team(store, %{
        "org_id" => org["id"],
        "slug" => "platform",
        "name" => "Platform"
      })

    payload = run_payload(%{"org_slug" => "false-systems", "team_slug" => "platform"})

    assert {:ok, record, :inserted} = Store.record_run(store, payload)
    assert record["run"]["team_id"] == team["id"]
    assert [%{"name" => "test"}] = record["nodes"]

    assert {:ok, ^record, :existing} = Store.record_run(store, payload)
    assert {:ok, ^record} = Store.get_run(store, "run_001")

    assert {:ok, [listed]} =
             Store.list_runs(store, %{"team_id" => team["id"], "status" => "passed"})

    assert listed["id"] == "run_001"

    assert {:ok, events} = Store.audit_log(store)
    assert Enum.count(events, &(&1["action"] == "run.recorded")) == 1

    org_id = org["id"]
    team_id = team["id"]

    assert [%{"org_id" => ^org_id, "team_id" => ^team_id}] =
             Enum.filter(events, &(&1["action"] == "run.recorded"))
  end

  test "record_run validates team and payload", %{store: store} do
    assert {:error, {:org_not_found, "false-systems"}} =
             Store.record_run(
               store,
               run_payload(%{"org_slug" => "false-systems", "team_slug" => "platform"})
             )

    {:ok, org} = Store.create_org(store, %{"slug" => "false-systems", "name" => "False Systems"})

    {:ok, _team} =
      Store.create_team(store, %{
        "org_id" => org["id"],
        "slug" => "platform",
        "name" => "Platform"
      })

    invalid_payload = put_in(run_payload(), ["run", "status"], "wat")
    assert {:error, :team_run_invalid_payload} = Store.record_run(store, invalid_payload)
  end

  defp run_payload(run_overrides \\ %{}) do
    %{
      "version" => "1",
      "run" =>
        Map.merge(
          %{
            "id" => "run_001",
            "org_slug" => "false-systems",
            "team_slug" => "platform",
            "status" => "passed"
          },
          run_overrides
        ),
      "nodes" => [%{"name" => "test", "kind" => "task", "status" => "passed"}],
      "criteria_results" => [],
      "review_results" => [],
      "gates" => [],
      "evidence_refs" => [%{"uri" => "file:///tmp/occurrence.json", "visibility" => "local_only"}]
    }
  end

  defp id_sequence(ids) do
    {:ok, agent} = Agent.start_link(fn -> ids end)

    fn ->
      Agent.get_and_update(agent, fn
        [id | rest] -> {id, rest}
        [] -> flunk("id sequence exhausted")
      end)
    end
  end

  describe "gate decision lifecycle (#202, #205)" do
    test "prunes sessions and their queues past the expiry" do
      {now_fun, advance} = ticking_now("2026-06-13T10:00:00Z")

      {:ok, store} =
        Store.start_link(now: now_fun, id: counter_ids(), session_expiry_seconds: 300)

      bootstrap(store)

      stale = join(store, "old-laptop")
      gate = publish_gate(store, stale, "gate_stale")
      decide(store, gate["id"])

      advance.(301)
      _fresh = join(store, "other-daemon")

      assert {:ok, sessions} = Store.list_daemon_sessions(store, %{})
      refute Enum.any?(sessions, &(&1["session_id"] == stale["session_id"]))

      assert {:error, {:daemon_session_not_found, _}} =
               Store.heartbeat_daemon_session(store, stale["session_id"], %{
                 "session_id" => stale["session_id"],
                 "status" => "available"
               })
    end

    test "rejoin after prune re-enqueues unacknowledged decisions from gate records" do
      {now_fun, advance} = ticking_now("2026-06-13T10:00:00Z")

      {:ok, store} =
        Store.start_link(now: now_fun, id: counter_ids(), session_expiry_seconds: 300)

      bootstrap(store)

      first = join(store, "yair-mbp")
      gate = publish_gate(store, first, "gate_rt")
      decide(store, gate["id"])

      # daemon goes dark past the cutoff; the queue dies with the session
      advance.(301)
      rejoined = join(store, "yair-mbp")

      assert {:ok, heartbeat, _session} =
               Store.heartbeat_daemon_session(store, rejoined["session_id"], %{
                 "session_id" => rejoined["session_id"],
                 "status" => "available"
               })

      assert [%{"id" => "gate_rt", "status" => "approved"}] = heartbeat["decisions"]
    end

    test "acknowledged decisions are not redelivered after rejoin" do
      {now_fun, advance} = ticking_now("2026-06-13T10:00:00Z")

      {:ok, store} =
        Store.start_link(now: now_fun, id: counter_ids(), session_expiry_seconds: 300)

      bootstrap(store)

      first = join(store, "yair-mbp")
      gate = publish_gate(store, first, "gate_done")
      decide(store, gate["id"])

      assert {:ok, %{"decisions" => [_delivered]}, _} =
               Store.heartbeat_daemon_session(store, first["session_id"], %{
                 "session_id" => first["session_id"],
                 "status" => "available"
               })

      assert {:ok, %{"decisions" => []}, _} =
               Store.heartbeat_daemon_session(store, first["session_id"], %{
                 "session_id" => first["session_id"],
                 "status" => "available",
                 "acknowledged_decision_ids" => ["gate_done"]
               })

      advance.(301)
      rejoined = join(store, "yair-mbp")

      assert {:ok, %{"decisions" => []}, _} =
               Store.heartbeat_daemon_session(store, rejoined["session_id"], %{
                 "session_id" => rejoined["session_id"],
                 "status" => "available"
               })
    end

    test "corrupted session team metadata reports invalid_session, not team_mismatch" do
      {now_fun, _advance} = ticking_now("2026-06-13T10:00:00Z")
      {:ok, store} = Store.start_link(now: now_fun, id: counter_ids())
      bootstrap(store)
      session = join(store, "yair-mbp")

      :sys.replace_state(store, fn state ->
        update_in(state, [:daemon_sessions, session["session_id"]], &Map.delete(&1, "team_id"))
      end)

      assert {:error, :team_gate_invalid_session} =
               Store.upsert_gate(store, gate_payload(session, "gate_corrupt"))
    end

    test "claiming a mismatched team still reports team_mismatch" do
      {now_fun, _advance} = ticking_now("2026-06-13T10:00:00Z")
      {:ok, store} = Store.start_link(now: now_fun, id: counter_ids())
      bootstrap(store)

      {:ok, _team2} =
        Store.create_team(store, %{
          "org_slug" => "false-systems",
          "slug" => "infra",
          "name" => "Infra"
        })

      session = join(store, "yair-mbp")
      payload = Map.put(gate_payload(session, "gate_x"), "team_slug", "infra")

      assert {:error, :team_gate_team_mismatch} = Store.upsert_gate(store, payload)
    end
  end

  defp ticking_now(start_iso) do
    {:ok, start, _offset} = DateTime.from_iso8601(start_iso)
    {:ok, agent} = Agent.start_link(fn -> start end)

    now_fun = fn -> Agent.get(agent, & &1) end
    advance = fn seconds -> Agent.update(agent, &DateTime.add(&1, seconds, :second)) end
    {now_fun, advance}
  end

  defp counter_ids do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    fn -> "id_#{Agent.get_and_update(agent, &{&1 + 1, &1 + 1})}" end
  end

  defp bootstrap(store) do
    {:ok, _org} = Store.create_org(store, %{"slug" => "false-systems", "name" => "FS"})

    {:ok, _team} =
      Store.create_team(store, %{
        "org_slug" => "false-systems",
        "slug" => "platform",
        "name" => "Platform"
      })

    :ok
  end

  defp join(store, daemon_id) do
    {:ok, _response, session} =
      Store.create_daemon_session(store, %{
        "org" => "false-systems",
        "team" => "platform",
        "daemon_id" => daemon_id,
        "labels" => [],
        "capabilities" => ["local"],
        "version" => "0.7.0",
        "accepts_remote_work" => false
      })

    session
  end

  defp gate_payload(session, gate_id) do
    %{
      "org_slug" => "false-systems",
      "team_slug" => "platform",
      "daemon_session_id" => session["session_id"],
      "id" => gate_id,
      "run_id" => "run_#{gate_id}",
      "node_id" => nil,
      "work_item_id" => nil,
      "status" => "waiting",
      "decided_by" => nil,
      "decided_at" => nil,
      "reason" => nil
    }
  end

  defp publish_gate(store, session, gate_id) do
    {:ok, gate, :inserted} = Store.upsert_gate(store, gate_payload(session, gate_id))
    gate
  end

  defp decide(store, gate_id) do
    {:ok, _gate} =
      Store.record_gate_decision(store, gate_id, %{
        "org_slug" => "false-systems",
        "team_slug" => "platform",
        "status" => "approved",
        "decided_by" => "member:reviewer",
        "decided_at" => "2026-06-13T10:01:00Z",
        "reason" => "Reviewed"
      })
  end
end
