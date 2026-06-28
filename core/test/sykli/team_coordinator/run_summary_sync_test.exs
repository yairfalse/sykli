defmodule Sykli.TeamCoordinator.RunSummarySyncTest do
  @moduledoc """
  Guards that run-summary sync is genuinely fire-and-forget (#246).

  `maybe_sync_run_summary/3` spawns the publish via `Task.Supervisor.start_child`,
  NOT `async_nolink`. `async_nolink` would monitor from the caller, leaving a
  `{ref, reply}` and a `{:DOWN, ...}` in the caller's mailbox — a leak for
  long-lived callers like the MCP server. This test drives a real run with a
  daemon session and asserts no such messages reach the caller.
  """
  use ExUnit.Case, async: false

  alias Sykli.Daemon.SessionStore
  alias Sykli.Occurrence

  @moduletag :tmp_dir

  setup do
    # No team token → the sync takes the network-free defer path (outbox + PubSub).
    prev = System.get_env("SYKLI_TEAM_TOKEN")
    System.delete_env("SYKLI_TEAM_TOKEN")
    on_exit(fn -> if prev, do: System.put_env("SYKLI_TEAM_TOKEN", prev) end)
    :ok
  end

  test "run-summary sync leaves no Task reply/:DOWN in the caller mailbox", %{tmp_dir: tmp_dir} do
    write_pipeline(tmp_dir, "true")

    {:ok, _} =
      SessionStore.write(
        %{
          "session_id" => "sess_test",
          "coordinator_url" => "http://127.0.0.1:0",
          "org" => "acme",
          "team" => "platform",
          "team_id" => "team_1",
          "daemon_id" => "d1"
        },
        path: Path.join(tmp_dir, ".sykli")
      )

    Sykli.Occurrence.PubSub.subscribe(:all)

    assert {:ok, _results} = Sykli.run(tmp_dir)

    # The deferred-sync occurrence is broadcast from inside the spawned task, so
    # receiving it proves the fire-and-forget publish actually ran.
    assert_receive %Occurrence{type: "ci.team.run.sync_deferred"}, 2_000

    # Give an async_nolink task (the regression) time to send its reply/:DOWN.
    # With start_child there is no monitor, so nothing ever arrives.
    Process.sleep(50)

    # async_nolink monitors from the caller, so it would deliver a :DOWN here.
    # start_child does not — the mailbox stays free of it.
    refute_received {:DOWN, _ref, :process, _pid, _reason}
  end

  defp write_pipeline(tmp_dir, command) do
    json =
      Jason.encode!(%{"version" => "1", "tasks" => [%{"name" => "test", "command" => command}]})

    File.write!(Path.join(tmp_dir, "sykli.exs"), "IO.puts(#{inspect(json)})")
  end
end
