defmodule Sykli.Occurrence.StoreTest do
  use ExUnit.Case, async: false

  alias Sykli.Occurrence.Store

  @tmp_dir System.tmp_dir!()

  setup do
    # Ensure no leftover store from previous test
    stop_store()

    test_dir = Path.join(@tmp_dir, "store_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      stop_store()
      File.rm_rf!(test_dir)
    end)

    {:ok, workdir: test_dir}
  end

  defp stop_store do
    if Process.whereis(Store) do
      GenServer.stop(Store)
    end
  catch
    :exit, _ -> :ok
  end

  defp start_store(opts \\ []) do
    {:ok, _pid} = Store.start_link(opts)
    :ok
  end

  describe "start_link/1" do
    test "starts successfully" do
      assert {:ok, pid} = Store.start_link()
      assert Process.alive?(pid)
    end

    test "creates named ETS table" do
      start_store()
      assert :ets.info(:sykli_occurrences) != :undefined
    end
  end

  describe "put/1 and get_latest/0" do
    test "stores and retrieves an occurrence" do
      start_store()
      occ = make_occurrence("run-1", "2026-01-01T00:00:00Z")

      assert :ok = Store.put(occ)
      assert Store.get_latest() == occ
    end

    test "get_latest returns newest occurrence" do
      start_store()
      old = make_occurrence("run-old", "2026-01-01T00:00:00Z")
      new = make_occurrence("run-new", "2026-01-02T00:00:00Z")

      Store.put(old)
      Store.put(new)

      assert Store.get_latest()["id"] == "run-new"
    end

    test "get_latest returns nil when empty" do
      start_store()
      assert Store.get_latest() == nil
    end
  end

  describe "get/1" do
    test "finds occurrence by id" do
      start_store()
      occ = make_occurrence("find-me", "2026-01-01T00:00:00Z")
      Store.put(occ)

      assert Store.get("find-me")["id"] == "find-me"
    end

    test "returns nil for unknown id" do
      start_store()
      assert Store.get("nonexistent") == nil
    end
  end

  describe "list/1" do
    test "returns occurrences newest first" do
      start_store()
      Store.put(make_occurrence("a", "2026-01-01T00:00:00Z"))
      Store.put(make_occurrence("b", "2026-01-02T00:00:00Z"))
      Store.put(make_occurrence("c", "2026-01-03T00:00:00Z"))

      ids = Store.list() |> Enum.map(& &1["id"])
      assert ids == ["c", "b", "a"]
    end

    test "respects limit option" do
      start_store()

      for i <- 1..5 do
        Store.put(make_occurrence("run-#{i}", "2026-01-0#{i}T00:00:00Z"))
      end

      assert length(Store.list(limit: 2)) == 2
    end

    test "filters by status" do
      start_store()
      Store.put(make_occurrence("pass-1", "2026-01-01T00:00:00Z", "success"))
      Store.put(make_occurrence("fail-1", "2026-01-02T00:00:00Z", "failure"))
      Store.put(make_occurrence("pass-2", "2026-01-03T00:00:00Z", "success"))

      passed = Store.list(status: "success")
      assert length(passed) == 2
      assert Enum.all?(passed, &(&1["outcome"] == "success"))

      failed = Store.list(status: "failure")
      assert length(failed) == 1
    end

    test "returns empty list when store is empty" do
      start_store()
      assert Store.list() == []
    end
  end

  describe "eviction" do
    test "evicts oldest entries when exceeding max" do
      start_store()

      # Insert 55 entries (max is 50)
      for i <- 1..55 do
        ts = "2026-01-01T00:00:#{String.pad_leading(Integer.to_string(i), 2, "0")}Z"
        Store.put(make_occurrence("run-#{i}", ts))
      end

      entries = Store.list(limit: 100)
      assert length(entries) == 50

      # Oldest 5 should be evicted
      ids = Enum.map(entries, & &1["id"])
      refute "run-1" in ids
      refute "run-5" in ids
      assert "run-6" in ids
      assert "run-55" in ids
    end
  end

  describe "ETS reads from other processes" do
    test "reads are accessible from spawned process" do
      start_store()
      occ = make_occurrence("cross-process", "2026-01-01T00:00:00Z")
      Store.put(occ)

      parent = self()

      spawn(fn ->
        result = Store.get_latest()
        send(parent, {:result, result})
      end)

      assert_receive {:result, %{"id" => "cross-process"}}, 1000
    end
  end

  describe "hydrate_from_disk/1" do
    test "loads .etf files into ETS", %{workdir: workdir} do
      etf_dir = Path.join([workdir, ".sykli", "occurrences"])
      File.mkdir_p!(etf_dir)

      occ = make_occurrence("from-disk", "2026-01-15T12:00:00Z")
      File.write!(Path.join(etf_dir, "from-disk.etf"), :erlang.term_to_binary(occ))

      start_store(workdir: workdir)

      assert Store.get("from-disk")["id"] == "from-disk"
    end

    test "handles missing .sykli/occurrences directory", %{workdir: workdir} do
      # No .sykli dir exists — should start cleanly
      start_store(workdir: workdir)
      assert Store.list() == []
    end

    test "limits hydration to 50 entries", %{workdir: workdir} do
      etf_dir = Path.join([workdir, ".sykli", "occurrences"])
      File.mkdir_p!(etf_dir)

      for i <- 1..60 do
        id = "bulk-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        ts = "2026-01-01T00:00:#{String.pad_leading(Integer.to_string(rem(i, 60)), 2, "0")}Z"
        occ = make_occurrence(id, ts)
        File.write!(Path.join(etf_dir, "#{id}.etf"), :erlang.term_to_binary(occ))
      end

      start_store(workdir: workdir)

      assert length(Store.list(limit: 100)) == 50
    end
  end

  describe "ETF round-trip" do
    test "ETF preserves occurrence data exactly", %{workdir: workdir} do
      etf_dir = Path.join([workdir, ".sykli", "occurrences"])
      File.mkdir_p!(etf_dir)

      original = %{
        "id" => "roundtrip",
        "timestamp" => "2026-01-01T00:00:00Z",
        "protocol_version" => "1.0",
        "outcome" => "failure",
        "context" => %{"labels" => %{}},
        "error" => %{
          "code" => "task_failed",
          "what_failed" => "test task"
        },
        "data" => %{
          "tasks" => [
            %{"name" => "test", "status" => "failed", "duration_ms" => 1500}
          ]
        }
      }

      File.write!(Path.join(etf_dir, "roundtrip.etf"), :erlang.term_to_binary(original))
      start_store(workdir: workdir)

      loaded = Store.get("roundtrip")
      assert loaded == original
    end

    test "loads old format (ci_data) for backward compat", %{workdir: workdir} do
      etf_dir = Path.join([workdir, ".sykli", "occurrences"])
      File.mkdir_p!(etf_dir)

      old_format = %{
        "id" => "old-format",
        "timestamp" => "2026-01-01T00:00:00Z",
        "version" => "1.0",
        "outcome" => "failed",
        "ci_data" => %{
          "tasks" => [
            %{"name" => "test", "status" => "failed", "duration_ms" => 1500}
          ]
        }
      }

      File.write!(Path.join(etf_dir, "old-format.etf"), :erlang.term_to_binary(old_format))
      start_store(workdir: workdir)

      loaded = Store.get("old-format")
      assert loaded["ci_data"]["tasks"] != nil
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FIXTURES
  # ─────────────────────────────────────────────────────────────────────────────

  defp make_occurrence(id, timestamp, outcome \\ "success") do
    type = if outcome == "success", do: "ci.run.passed", else: "ci.run.failed"

    %{
      "id" => id,
      "timestamp" => timestamp,
      "outcome" => outcome,
      "protocol_version" => "1.0",
      "source" => "sykli",
      "type" => type,
      "severity" => if(outcome == "success", do: "info", else: "error"),
      "context" => %{"labels" => %{}},
      "history" => %{"steps" => [], "duration_ms" => 0},
      "data" => %{"summary" => %{}, "tasks" => [], "git" => %{}}
    }
  end

  defp make_occurrence_with_tasks(id, timestamp, tasks) do
    %{
      "id" => id,
      "timestamp" => timestamp,
      "outcome" => "success",
      "protocol_version" => "1.0",
      "source" => "sykli",
      "type" => "ci.run.passed",
      "severity" => "info",
      "context" => %{"labels" => %{}},
      "history" => %{"steps" => [], "duration_ms" => 0},
      "data" => %{"summary" => %{}, "tasks" => tasks, "git" => %{}}
    }
  end
end
