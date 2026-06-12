defmodule Sykli.Daemon.LeaveTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Sykli.Daemon.Leave
  alias Sykli.Daemon.SessionStore

  defmodule OfflineClient do
    def post_json(url, path, token, payload) do
      send(:persistent_term.get({__MODULE__, :pid}), {:offline_posted, url, path, token, payload})
      {:ok, %{"next_heartbeat_seconds" => 15, "decisions" => [], "assignments" => []}}
    end
  end

  defmodule DownClient do
    def post_json(_url, _path, _token, _payload),
      do: {:error, {:coordinator_unavailable, :econnrefused}}
  end

  setup do
    :persistent_term.put({__MODULE__.OfflineClient, :pid}, self())

    tmp = Path.join(System.tmp_dir!(), "sykli-leave-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  defp write_session(tmp) do
    {:ok, _} =
      SessionStore.write(
        %{
          "coordinator" => "https://sykli.internal",
          "org" => "false-systems",
          "team" => "platform",
          "daemon_id" => "yair-mbp",
          "session_id" => "sess_001",
          "labels" => ["macos"],
          "capabilities" => ["local"]
        },
        path: tmp
      )
  end

  test "leave notifies offline, removes the session, and reports json", %{tmp: tmp} do
    write_session(tmp)

    output =
      capture_io(fn ->
        assert Leave.leave([json: true, path: tmp, token: "tok"], client: OfflineClient) == 0
      end)

    assert_received {:offline_posted, "https://sykli.internal",
                     "/v1/daemon-sessions/sess_001/heartbeat", "tok", payload}

    assert payload["status"] == "offline"
    assert payload["session_id"] == "sess_001"

    decoded = Jason.decode!(output)
    assert decoded["data"]["left"] == true
    assert decoded["data"]["coordinator_notified"] == true
    assert {:error, :daemon_session_not_found} = SessionStore.read(path: tmp)
  end

  test "leave still removes the session when the coordinator is down", %{tmp: tmp} do
    write_session(tmp)

    output =
      capture_io(fn ->
        assert Leave.leave([json: true, path: tmp, token: "tok"], client: DownClient) == 0
      end)

    decoded = Jason.decode!(output)
    assert decoded["data"]["left"] == true
    assert decoded["data"]["coordinator_notified"] == false
    assert {:error, :daemon_session_not_found} = SessionStore.read(path: tmp)
  end

  test "leave without a token skips the notification but removes the session", %{tmp: tmp} do
    previous = System.get_env("SYKLI_TEAM_TOKEN")
    System.delete_env("SYKLI_TEAM_TOKEN")
    on_exit(fn -> if previous, do: System.put_env("SYKLI_TEAM_TOKEN", previous) end)

    write_session(tmp)

    output =
      capture_io(fn ->
        assert Leave.leave([json: true, path: tmp], client: OfflineClient) == 0
      end)

    refute_received {:offline_posted, _, _, _, _}
    assert Jason.decode!(output)["data"]["coordinator_notified"] == false
    assert {:error, :daemon_session_not_found} = SessionStore.read(path: tmp)
  end

  test "leave without a session is an idempotent success", %{tmp: tmp} do
    output =
      capture_io(fn ->
        assert Leave.leave([json: true, path: tmp], client: OfflineClient) == 0
      end)

    decoded = Jason.decode!(output)
    assert decoded["data"]["left"] == false
    assert decoded["data"]["reason"] == "not_joined"
  end

  test "human output reports the leave" do
    tmp = Path.join(System.tmp_dir!(), "sykli-leave-h-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)
    write_session(tmp)

    output =
      capture_io(fn ->
        assert Leave.leave([path: tmp, token: "tok"], client: OfflineClient) == 0
      end)

    assert output =~ "Left coordinator https://sykli.internal"
  end

  test "unknown flag is rejected" do
    output =
      capture_io(:stderr, fn ->
        assert Leave.run(["--nope"]) == 1
      end)

    assert output =~ "daemon.invalid_leave_command"
  end
end
