defmodule Sykli.Daemon.HeartbeatTest do
  use ExUnit.Case, async: false

  alias Sykli.Daemon.Heartbeat

  # The loop persists liveness through a session-store double so tests never
  # touch the real `.sykli/daemon/session.json`.
  defmodule NullStore do
    def read(_opts), do: {:error, :enoent}
    def write(session, _opts), do: {:ok, session}
  end

  # The loop calls write/2 from its own process, so the test pid travels via
  # persistent_term (async: false keeps this race-free across tests).
  defmodule RecordingStore do
    def read(_opts), do: {:error, :enoent}

    def write(session, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:liveness, session})
      {:ok, session}
    end

    def record_to(pid), do: :persistent_term.put({__MODULE__, :test_pid}, pid)
  end

  defp session(overrides \\ %{}) do
    Map.merge(
      %{
        "coordinator" => "https://coordinator.test",
        "session_id" => "sess_test",
        "daemon_id" => "test-daemon",
        "heartbeat_interval_seconds" => 15,
        "labels" => ["macos"],
        "capabilities" => ["local"],
        "accepts_remote_work" => false
      },
      overrides
    )
  end

  defp start_loop(opts) do
    test_pid = self()

    defaults = [
      name: nil,
      token: "tok_test",
      session: session(),
      session_store: NullStore,
      outbox_drain: fn -> send(test_pid, :outbox_drained) end,
      jitter_fun: fn _max -> 0 end,
      now_fun: fn -> "2026-06-12T00:00:00Z" end,
      schedule_fun: fn ms ->
        send(test_pid, {:scheduled, ms})
        make_ref()
      end
    ]

    opts = Keyword.merge(defaults, opts)
    start_supervised!({Heartbeat, opts}, restart: :temporary)
  end

  defp ok_response(extra \\ %{}) do
    {:ok,
     Map.merge(
       %{"next_heartbeat_seconds" => 15, "decisions" => [], "assignments" => []},
       extra
     )}
  end

  test "refuses to start without a session" do
    assert :ignore =
             Heartbeat.start_link(
               name: nil,
               token: "tok_test",
               session_store: NullStore
             )
  end

  test "refuses to start without a token" do
    previous = System.get_env("SYKLI_TEAM_TOKEN")
    System.delete_env("SYKLI_TEAM_TOKEN")
    on_exit(fn -> if previous, do: System.put_env("SYKLI_TEAM_TOKEN", previous) end)

    assert :ignore =
             Heartbeat.start_link(
               name: nil,
               token: nil,
               session: session(),
               session_store: NullStore
             )
  end

  test "schedules the first tick immediately and follows next_heartbeat_seconds" do
    test_pid = self()

    pid =
      start_loop(
        post_fun: fn _session, payload ->
          send(test_pid, {:posted, payload})
          ok_response(%{"next_heartbeat_seconds" => 7})
        end
      )

    assert_receive {:scheduled, 0}
    send(pid, :heartbeat)

    assert_receive {:posted, payload}
    assert payload["session_id"] == "sess_test"
    assert payload["status"] == "available"
    assert payload["acknowledged_decision_ids"] == []

    assert_receive {:scheduled, 7_000}
  end

  test "drains the outbox on the first successful heartbeat and after failures" do
    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> [:fail, :ok, :ok, :fail, :ok] end)

    pid =
      start_loop(
        post_fun: fn _session, _payload ->
          case Agent.get_and_update(agent, fn [h | t] -> {h, t} end) do
            :ok -> ok_response()
            :fail -> {:error, {:coordinator_unavailable, :econnrefused}}
          end
        end,
        outbox_drain: fn -> send(test_pid, :outbox_drained) end
      )

    assert_receive {:scheduled, 0}

    # fail → success: drains (recovery is also the first success)
    send(pid, :heartbeat)
    refute_receive :outbox_drained, 50
    send(pid, :heartbeat)
    assert_receive :outbox_drained

    # steady-state success: no drain
    send(pid, :heartbeat)
    refute_receive :outbox_drained, 50

    # fail → success: drains again
    send(pid, :heartbeat)
    send(pid, :heartbeat)
    assert_receive :outbox_drained
  end

  test "acknowledges applied gate decisions on the following tick" do
    test_pid = self()
    tmp = Path.join(System.tmp_dir!(), "hb-gates-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, gate} = Sykli.GateDecision.new(id: "gate_1")
    :ok = Sykli.Gate.Store.save(gate, path: tmp)

    # apply_remote_decision keys the local gate by the decision's "id".
    decision = %{
      "id" => "gate_1",
      "status" => "approved",
      "decided_by" => "member:yair",
      "reason" => "test"
    }

    {:ok, agent} = Agent.start_link(fn -> [{:ok_with, [decision]}, :plain_ok] end)

    pid =
      start_loop(
        post_fun: fn _session, payload ->
          send(test_pid, {:posted, payload})

          case Agent.get_and_update(agent, fn [h | t] -> {h, t} end) do
            {:ok_with, decisions} -> ok_response(%{"decisions" => decisions})
            :plain_ok -> ok_response()
          end
        end,
        gate_opts: [path: tmp]
      )

    assert_receive {:scheduled, 0}
    send(pid, :heartbeat)
    assert_receive {:posted, %{"acknowledged_decision_ids" => []}}

    send(pid, :heartbeat)
    assert_receive {:posted, %{"acknowledged_decision_ids" => acked}}
    assert acked == ["gate_1"]
  end

  test "backs off exponentially with a cap of interval * 4" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    pid =
      start_loop(
        post_fun: fn _session, _payload ->
          Agent.update(agent, &(&1 + 1))
          {:error, {:coordinator_unavailable, :econnrefused}}
        end,
        jitter_fun: fn _max -> 0 end
      )

    assert_receive {:scheduled, 0}

    # interval 15s, cap 60s. step = min(15 * 2^n, 60); delay = step/2 + 0
    send(pid, :heartbeat)
    assert_receive {:scheduled, 15_000}

    send(pid, :heartbeat)
    assert_receive {:scheduled, 30_000}

    send(pid, :heartbeat)
    assert_receive {:scheduled, 30_000}

    send(pid, :heartbeat)
    assert_receive {:scheduled, 30_000}
  end

  test "stops on 401 and never retries the token" do
    RecordingStore.record_to(self())

    pid =
      start_loop(
        post_fun: fn _session, _payload ->
          {:error, {:coordinator_error, 401, %{"message" => "revoked"}}}
        end,
        session_store: RecordingStore
      )

    ref = Process.monitor(pid)
    assert_receive {:scheduled, 0}
    send(pid, :heartbeat)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_receive {:liveness, %{"revoked" => true}}
    refute_receive {:scheduled, _}, 50
  end

  test "persists liveness fields on success and failure" do
    RecordingStore.record_to(self())
    {:ok, agent} = Agent.start_link(fn -> [:ok, :fail] end)

    pid =
      start_loop(
        post_fun: fn _session, _payload ->
          case Agent.get_and_update(agent, fn [h | t] -> {h, t} end) do
            :ok -> ok_response()
            :fail -> {:error, {:coordinator_unavailable, :timeout}}
          end
        end,
        session_store: RecordingStore
      )

    assert_receive {:scheduled, 0}

    send(pid, :heartbeat)

    assert_receive {:liveness,
                    %{"consecutive_failures" => 0, "last_heartbeat_at" => "2026-06-12T00:00:00Z"}}

    send(pid, :heartbeat)
    assert_receive {:liveness, %{"consecutive_failures" => 1}}
  end

  test "rejoins automatically when the coordinator forgot the session" do
    test_pid = self()

    {:ok, agent} =
      Agent.start_link(fn ->
        [
          {:error,
           {:coordinator_error, 404, %{"code" => "coordinator.daemon_session_not_found"}}},
          :plain_ok
        ]
      end)

    pid =
      start_loop(
        post_fun: fn session, payload ->
          send(test_pid, {:posted, session["session_id"], payload})

          case Agent.get_and_update(agent, fn [h | t] -> {h, t} end) do
            :plain_ok -> ok_response()
            other -> other
          end
        end,
        join_fun: fn _session, payload ->
          send(test_pid, {:rejoined, payload})
          {:ok, %{"session_id" => "sess_new", "heartbeat_interval_seconds" => 20}}
        end
      )

    assert_receive {:scheduled, 0}
    send(pid, :heartbeat)
    assert_receive {:posted, "sess_test", _payload}

    assert_receive {:rejoined, join_payload}
    assert join_payload["daemon_id"] == "test-daemon"
    assert join_payload["accepts_remote_work"] == false

    # rejoin schedules an immediate tick under the fresh session
    assert_receive {:scheduled, 0}
    send(pid, :heartbeat)
    assert_receive {:posted, "sess_new", _payload}
  end

  test "sends a final offline heartbeat on shutdown after a successful sync" do
    test_pid = self()

    pid =
      start_loop(
        post_fun: fn _session, payload ->
          send(test_pid, {:posted, payload})
          ok_response()
        end
      )

    assert_receive {:scheduled, 0}
    send(pid, :heartbeat)
    assert_receive {:posted, %{"status" => "available"}}

    GenServer.stop(pid)
    assert_receive {:posted, %{"status" => "offline"}}
  end

  test "does not send an offline heartbeat if it never synced" do
    test_pid = self()

    pid =
      start_loop(
        post_fun: fn _session, payload ->
          send(test_pid, {:posted, payload})
          ok_response()
        end
      )

    assert_receive {:scheduled, 0}
    GenServer.stop(pid)
    refute_receive {:posted, _}, 50
  end

  test "reports draining status once drain/1 is cast" do
    test_pid = self()

    pid =
      start_loop(
        post_fun: fn _session, payload ->
          send(test_pid, {:posted, payload})
          ok_response()
        end
      )

    assert_receive {:scheduled, 0}
    Heartbeat.drain(pid)
    send(pid, :heartbeat)

    assert_receive {:posted, %{"status" => "draining"}}
  end
end
