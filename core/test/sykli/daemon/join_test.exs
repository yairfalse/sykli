defmodule Sykli.Daemon.JoinTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Sykli.Daemon.Join

  @now "2026-05-09T10:00:00Z"

  test "builds join payload with labels capabilities and remote work disabled by default" do
    assert {:ok, payload} =
             Join.build_join_payload(
               [
                 coordinator: "https://sykli.internal",
                 org: "false-systems",
                 team: "platform",
                 token: "secret",
                 labels: "macos,docker",
                 name: "yair-mbp"
               ],
               version: "0.6.1"
             )

    assert payload["daemon_id"] == "yair-mbp"
    assert payload["labels"] == ["macos", "docker"]
    assert payload["capabilities"] == ["local"]
    assert payload["version"] == "0.6.1"
    assert payload["accepts_remote_work"] == false
    refute Map.has_key?(payload, "token")
  end

  test "heartbeat payload is shaped for coordinator" do
    session = %{"session_id" => "sess_001", "labels" => ["macos"], "capabilities" => ["local"]}

    assert Join.heartbeat_payload(session, %{"last_run_id" => "run_001"}) == %{
             "session_id" => "sess_001",
             "status" => "available",
             "current_work_item_id" => nil,
             "labels" => ["macos"],
             "capabilities" => ["local"],
             "last_run_id" => "run_001",
             "acknowledged_decision_ids" => []
           }
  end

  test "successful join persists session and does not print token" do
    tmp = Path.join(System.tmp_dir!(), "sykli-join-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)

    output =
      capture_io(fn ->
        assert Join.join(
                 [
                   coordinator: "https://sykli.internal",
                   org: "false-systems",
                   team: "platform",
                   token: "super-secret",
                   labels: "macos,docker",
                   name: "yair-mbp",
                   json: true,
                   path: tmp
                 ],
                 client: __MODULE__.FakeClient,
                 now: @now,
                 version: "0.6.1"
               ) == 0
      end)

    decoded = Jason.decode!(output)
    assert decoded["data"]["session"]["session_id"] == "sess_001"
    refute output =~ "super-secret"

    {:ok, file} = File.read(Sykli.Daemon.SessionStore.path(path: tmp))
    refute file =~ "super-secret"
  end

  test "join accepts token from environment without persisting it" do
    tmp =
      Path.join(System.tmp_dir!(), "sykli-join-env-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(tmp) end)

    System.put_env("SYKLI_TEAM_TOKEN", "super-secret")
    on_exit(fn -> System.delete_env("SYKLI_TEAM_TOKEN") end)

    capture_io(fn ->
      assert Join.join(
               [
                 coordinator: "https://sykli.internal",
                 org: "false-systems",
                 team: "platform",
                 name: "yair-mbp",
                 json: true,
                 path: tmp
               ],
               client: __MODULE__.FakeClient,
               now: @now,
               version: "0.6.1"
             ) == 0
    end)

    {:ok, file} = File.read(Sykli.Daemon.SessionStore.path(path: tmp))
    refute file =~ "super-secret"
  end

  test "join help works after subcommand name" do
    output =
      capture_io(fn ->
        assert Join.run(["join", "--help"]) == 0
      end)

    assert output =~ "Usage: sykli daemon join"
  end

  test "missing required args return structured json error" do
    output =
      capture_io(fn ->
        assert Join.run(["join", "--org", "false-systems", "--json"]) == 1
      end)

    assert Jason.decode!(output)["error"]["code"] == "daemon.join_missing_coordinator"
  end

  test "heartbeat response only acknowledges applied gate decisions" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "sykli-join-gate-ack-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(tmp) end)

    decision = %{
      "id" => "missing_gate",
      "run_id" => "run_001",
      "status" => "approved",
      "decided_by" => "member:reviewer",
      "decided_at" => @now,
      "reason" => "Reviewed"
    }

    Sykli.Occurrence.PubSub.subscribe("run_001")

    assert {:ok, []} = Join.apply_heartbeat_response(%{"decisions" => [decision]}, path: tmp)
    assert_receive %Sykli.Occurrence{type: "ci.team.gate.apply_failed"}, 500
  end

  test "heartbeat response drops a gate decision after repeated apply failures" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "sykli-join-gate-retry-cap-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(tmp) end)

    decision = %{
      "id" => "missing_gate_retry",
      "run_id" => "run_001",
      "status" => "approved",
      "decided_by" => "member:reviewer",
      "decided_at" => @now,
      "reason" => "Reviewed"
    }

    Sykli.Occurrence.PubSub.subscribe("run_001")

    for _ <- 1..10 do
      assert {:ok, []} =
               Join.apply_heartbeat_response(%{"decisions" => [decision]},
                 path: tmp,
                 session_id: "sess_001"
               )
    end

    assert {:ok, ["missing_gate_retry"]} =
             Join.apply_heartbeat_response(%{"decisions" => [decision]},
               path: tmp,
               session_id: "sess_001"
             )

    for _ <- 1..11 do
      assert_receive %Sykli.Occurrence{
                       type: "ci.team.gate.apply_failed",
                       data: %{"id" => "missing_gate_retry"}
                     },
                     500
    end
  end

  test "join --stay runs the heartbeat host and returns when it stops" do
    tmp = Path.join(System.tmp_dir!(), "sykli-stay-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)

    output =
      capture_io(fn ->
        assert Join.join(
                 [
                   coordinator: "https://sykli.internal",
                   org: "false-systems",
                   team: "platform",
                   token: "super-secret",
                   name: "yair-mbp",
                   stay: true,
                   path: tmp
                 ],
                 client: __MODULE__.FakeClient,
                 heartbeat: __MODULE__.InstantHeartbeat,
                 now: @now,
                 version: "0.6.1"
               ) == 0
      end)

    assert output =~ "Heartbeat loop running"
    assert_received {:stay_started, opts}
    assert opts[:session]["session_id"] == "sess_001"
    assert opts[:token] == "super-secret"
    assert opts[:path] == tmp
  end

  test "join --stay surfaces a refused heartbeat start" do
    tmp =
      Path.join(System.tmp_dir!(), "sykli-stay-ignore-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(tmp) end)

    output =
      capture_io(:stderr, fn ->
        assert Join.join(
                 [
                   coordinator: "https://sykli.internal",
                   org: "false-systems",
                   team: "platform",
                   token: "super-secret",
                   name: "yair-mbp",
                   stay: true,
                   path: tmp
                 ],
                 client: __MODULE__.FakeClient,
                 heartbeat: __MODULE__.IgnoringHeartbeat,
                 now: @now,
                 version: "0.6.1"
               ) == 1
      end)

    assert output =~ "daemon.stay_failed"
  end

  test "accepts the --stay flag in command parsing" do
    output =
      capture_io(:stderr, fn ->
        assert Join.run(["join", "--stay"]) == 1
      end)

    assert output =~ "daemon.join_missing_coordinator"
    refute output =~ "invalid_join_command"
  end

  defmodule InstantHeartbeat do
    def start_link(opts) do
      send(self_test_pid(), {:stay_started, opts})
      {:ok, spawn(fn -> :ok end)}
    end

    defp self_test_pid, do: :persistent_term.get({__MODULE__, :pid})
  end

  defmodule IgnoringHeartbeat do
    def start_link(_opts), do: :ignore
  end

  setup do
    :persistent_term.put({__MODULE__.InstantHeartbeat, :pid}, self())
    :ok
  end

  defmodule FakeClient do
    def post_json(_url, "/v1/daemon-sessions", "super-secret", payload) do
      if Map.has_key?(payload, "token") do
        raise "join payload leaked token"
      end

      {:ok,
       %{
         "session_id" => "sess_001",
         "heartbeat_interval_seconds" => 15,
         "team_id" => "team_001",
         "policy" => %{
           "sync_run_summaries" => true,
           "sync_evidence_refs" => true,
           "upload_raw_logs_by_default" => false
         }
       }}
    end
  end
end
