defmodule Sykli.Gui.Provider.ArtifactTest do
  use ExUnit.Case, async: true

  alias Sykli.Gui.Provider.Artifact
  alias Sykli.Gui.State
  alias Sykli.RunHistory

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "sykli-gui-artifact-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp save_run(tmp, id, timestamp, overall, tasks, opts \\ []) do
    :ok =
      RunHistory.save(
        %RunHistory.Run{
          id: id,
          timestamp: timestamp,
          git_ref: "abc123",
          git_branch: "main",
          tasks: tasks,
          overall: overall,
          work_item_id: Keyword.get(opts, :work_item_id)
        },
        path: tmp
      )
  end

  defp task(name, status, opts \\ []) do
    %RunHistory.TaskResult{
      name: name,
      status: status,
      duration_ms: Keyword.get(opts, :duration_ms, 100),
      error: Keyword.get(opts, :error),
      cached: Keyword.get(opts, :cached, false)
    }
  end

  describe "state/1 on an empty repo" do
    test "returns an empty but encodable state", %{tmp: tmp} do
      state = Artifact.state(repo_path: tmp)

      refute state.contract.valid
      assert state.latest_run == nil
      assert state.graph == %{nodes: [], edges: []}
      assert state.work_items == []
      assert state.gates == []
      assert state.evidence == []
      assert state.activity == []
      assert state.agent_calls == []
      assert state.current_actor["ref"] =~ ~r/^member:/
      assert [%State.Member{identity_type: "human"}] = state.members
      assert %{"currentActor" => %{"ref" => actor_ref}} = State.to_wire(state)
      assert actor_ref == state.current_actor["ref"]
    end

    test "repo falls back to directory name outside git", %{tmp: tmp} do
      state = Artifact.state(repo_path: tmp)

      assert state.repo.name == Path.basename(tmp)
      assert state.repo.branch == "unknown"
      refute state.repo.dirty
    end
  end

  describe "state/1 with run history" do
    test "latest run, graph nodes, evidence, and activity come from manifests", %{tmp: tmp} do
      save_run(tmp, "run-old", ~U[2026-07-01 10:00:00Z], :passed, [
        task("format", :passed),
        task("test", :passed, duration_ms: 2400)
      ])

      save_run(tmp, "run-new", ~U[2026-07-02 11:30:00Z], :failed, [
        task("format", :passed),
        task("test", :failed, error: "boom"),
        task("build", :skipped, error: "dependency_failed", duration_ms: 0)
      ])

      state = Artifact.state(repo_path: tmp)

      assert state.latest_run.id == "run-new"
      assert state.latest_run.status == "failed"
      assert state.latest_run.primary_failure_node_id == "test"
      assert state.latest_run.started_at =~ "2026-07-02"

      # No contract artifacts: nodes fall back to the latest run, no edges.
      assert %{nodes: nodes, edges: []} = state.graph
      assert Enum.map(nodes, & &1.id) == ["format", "test", "build"]
      assert Enum.map(nodes, & &1.status) == ["passed", "failed", "skipped"]
      assert Enum.find(nodes, &(&1.id == "build")).reason == "dependency_failed"

      assert [%State.Evidence{run_id: "run-new", failed: 1, skipped: 1} | _] = state.evidence
      assert length(state.evidence) == 2

      assert Enum.any?(state.activity, &(&1.text =~ "test failed" and &1.kind == "fail"))
      assert Enum.all?(state.activity, &(&1.time == "11:30"))
    end

    test "run/2 returns the manifest detail", %{tmp: tmp} do
      save_run(tmp, "run-detail", ~U[2026-07-02 11:30:00Z], :passed, [
        task("format", :passed, cached: true)
      ])

      assert {:ok, detail} = Artifact.run("run-detail", repo_path: tmp)
      assert detail["status"] == "passed"
      assert [%{"name" => "format", "status" => "cached"}] = detail["taskResults"]

      assert {:error, :not_found} = Artifact.run("run-missing", repo_path: tmp)
    end
  end

  describe "state/1 contract sources" do
    test "reads structure from .sykli/context.json without executing anything", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, ".sykli"))

      context =
        Jason.encode!(%{
          "pipeline" => %{
            "tasks" => [
              %{"name" => "a"},
              %{"name" => "b", "depends_on" => ["a"]}
            ]
          }
        })

      File.write!(Path.join(tmp, ".sykli/context.json"), context)

      state = Artifact.state(repo_path: tmp)

      assert state.contract.valid
      assert state.contract.task_count == 2
      assert state.contract.version == nil

      assert %{nodes: nodes, edges: [%State.Edge{from: "a", to: "b"}]} = state.graph
      assert Enum.all?(nodes, &(&1.status == "pending"))
    end

    test "prefers sykli.lock and counts gates and review nodes", %{tmp: tmp} do
      contract = %{
        "version" => "5",
        "tasks" => [
          %{"name" => "test", "command" => "make test"},
          %{"name" => "review", "kind" => "review", "primitive" => "api_breakage"},
          %{"name" => "ship", "gate" => %{"approvers" => ["yair"]}, "needs" => ["test"]}
        ]
      }

      lock = Sykli.ContractLock.build(contract, "sykli.exs")
      {:ok, _bytes} = Sykli.ContractLock.write(lock, Path.join(tmp, "sykli.lock"))

      state = Artifact.state(repo_path: tmp)

      assert state.contract.version == 5
      assert state.contract.task_count == 3
      assert state.contract.gate_count == 1
      assert state.contract.review_node_count == 1

      types = Map.new(state.graph.nodes, &{&1.id, &1.type})
      assert types == %{"test" => "task", "review" => "review", "ship" => "gate"}
      assert state.graph.edges == [%State.Edge{from: "test", to: "ship"}]
    end
  end

  describe "state/1 with work items and gates" do
    test "work items list with associated run counts", %{tmp: tmp} do
      {:ok, item} =
        Sykli.Work.Store.create("fix flaky test",
          path: tmp,
          intent: "Fix the flaky test",
          created_by_type: "agent",
          created_by_id: "codex"
        )

      save_run(tmp, "run-w1", ~U[2026-07-02 09:00:00Z], :failed, [task("test", :failed)],
        work_item_id: item.id
      )

      state = Artifact.state(repo_path: tmp)

      assert [row] = state.work_items
      assert row.id == item.id
      assert row.title == "fix flaky test"
      assert row.owner == "codex"
      assert row.runs == 1
      assert row.run_list =~ "failed"
    end

    test "waiting gates appear in gates and activity", %{tmp: tmp} do
      {:ok, gate} =
        Sykli.Gate.Store.create(
          path: tmp,
          requested_by_type: "agent",
          requested_by_id: "codex",
          run_id: "run-42"
        )

      state = Artifact.state(repo_path: tmp)

      assert [row] = state.gates
      assert row.id == gate.id
      assert row.status == "waiting"
      assert row.requester == "codex"
      assert row.run_id == "run-42"

      assert Enum.any?(state.activity, &(&1.kind == "wait" and &1.text =~ gate.id))
    end
  end

  describe "gate decisions" do
    test "approve writes through Gate.Store with qualified actor", %{tmp: tmp} do
      {:ok, gate} = Sykli.Gate.Store.create(path: tmp)

      actor = Artifact.state(repo_path: tmp).current_actor["ref"]

      assert {:ok, wire} = Artifact.approve_gate(gate.id, actor, repo_path: tmp)
      assert wire["status"] == "approved"
      assert wire["decidedBy"] == actor

      assert {:ok, stored} = Sykli.Gate.Store.get(gate.id, path: tmp)
      assert stored.status == "approved"
      assert stored.decided_by == actor
    end

    test "reject records the reason and keeps qualified actor refs intact", %{tmp: tmp} do
      {:ok, gate} = Sykli.Gate.Store.create(path: tmp)

      assert {:ok, wire} =
               Artifact.reject_gate(gate.id, "agent:codex", "not ready", repo_path: tmp)

      assert wire["status"] == "rejected"
      assert wire["decidedBy"] == "agent:codex"
      assert wire["reason"] == "not ready"
    end

    test "unknown gate id maps to :not_found", %{tmp: tmp} do
      missing_id = Sykli.ULID.generate()
      assert {:error, :not_found} = Artifact.approve_gate(missing_id, "yair", repo_path: tmp)
    end
  end
end
