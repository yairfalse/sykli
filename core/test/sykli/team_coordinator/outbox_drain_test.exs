defmodule Sykli.TeamCoordinator.OutboxDrainTest do
  @moduledoc """
  Guards that the team outbox drain reads the workdir it was given, not cwd (#203).

  The executor enqueues deferred syncs with `Outbox.enqueue(..., path: workdir)`.
  Before the fix the drain dropped its opts and defaulted to cwd, so a run whose
  workdir differs from the daemon's cwd silently never drained.
  """
  use ExUnit.Case, async: true

  alias Sykli.Outbox
  alias Sykli.TeamCoordinator.OutboxDrain

  @moduletag :tmp_dir

  # A payload whose daemon_session_id won't match the draining session is a
  # permanent invalid payload, so the drain drops it WITHOUT any network call —
  # letting us prove the drain found the file purely by which outbox it read.
  defp enqueue_unmatched_gate(workdir) do
    payload = %{"id" => "gate_001", "daemon_session_id" => "other-session"}
    assert :ok = Outbox.enqueue("gates", payload, path: workdir)
  end

  test "drain_gates with :path reads that workdir's outbox", %{tmp_dir: tmp_dir} do
    enqueue_unmatched_gate(tmp_dir)
    assert {:ok, 1} = Outbox.pending_count("gates", path: tmp_dir)

    OutboxDrain.drain_gates(session: %{"session_id" => "my-session"}, token: "t", path: tmp_dir)

    # Found and dropped (permanent invalid) — proves the drain read tmp_dir, not cwd.
    assert {:ok, 0} = Outbox.pending_count("gates", path: tmp_dir)
  end

  test "drain_gates without :path leaves a different workdir's outbox untouched",
       %{tmp_dir: tmp_dir} do
    enqueue_unmatched_gate(tmp_dir)

    # No :path → operates on cwd, so tmp_dir's outbox is not its concern.
    OutboxDrain.drain_gates(session: %{"session_id" => "my-session"}, token: "t")

    assert {:ok, 1} = Outbox.pending_count("gates", path: tmp_dir)
  end
end
