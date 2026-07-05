defmodule Sykli.RunHistoryTest do
  use ExUnit.Case, async: true

  alias Sykli.RunHistory

  @moduletag :tmp_dir

  describe "save/2" do
    test "saves run manifest to .sykli/runs directory", %{tmp_dir: tmp_dir} do
      run = %RunHistory.Run{
        id: "test-run-1",
        timestamp: ~U[2024-01-15 10:30:00Z],
        git_ref: "abc1234",
        git_branch: "main",
        work_item_id: "work_001",
        contract_hash: "sha256:abc",
        tasks: [
          %RunHistory.TaskResult{name: "test", status: :passed, duration_ms: 1234}
        ],
        overall: :passed
      }

      assert :ok = RunHistory.save(run, path: tmp_dir)

      # Check file was created
      runs_dir = Path.join([tmp_dir, ".sykli", "runs"])
      assert File.dir?(runs_dir)

      files = File.ls!(runs_dir)
      assert Enum.any?(files, &String.ends_with?(&1, ".json"))

      assert {:ok, loaded} = RunHistory.load_latest(path: tmp_dir)
      assert loaded.work_item_id == "work_001"
      assert loaded.contract_hash == "sha256:abc"
    end

    test "round-trips task failure semantics", %{tmp_dir: tmp_dir} do
      run = %RunHistory.Run{
        id: "failure-semantics-run",
        timestamp: ~U[2024-01-15 10:30:00Z],
        git_ref: "abc1234",
        git_branch: "main",
        tasks: [
          %RunHistory.TaskResult{
            name: "test",
            status: :failed,
            duration_ms: 100,
            error: "success_criteria_failed: task failed success_criteria",
            failure_semantics:
              Sykli.FailureSemantics.criteria_failure(
                "success_criteria_failed",
                "task failed success_criteria"
              )
          }
        ],
        overall: :failed
      }

      assert :ok = RunHistory.save(run, path: tmp_dir)
      assert {:ok, loaded} = RunHistory.load_latest(path: tmp_dir)
      [task] = loaded.tasks

      assert %Sykli.FailureSemantics{
               class: :criteria_failure,
               source: :criteria,
               retryable: false,
               reason: "success_criteria_failed"
             } = task.failure_semantics
    end

    test "round-trips contract slice and success criteria results", %{tmp_dir: tmp_dir} do
      run = %RunHistory.Run{
        id: "contract-slice-run",
        timestamp: ~U[2024-01-15 10:30:00Z],
        git_ref: "abc1234",
        git_branch: "main",
        tasks: [
          %RunHistory.TaskResult{
            name: "test",
            status: :failed,
            duration_ms: 100,
            contract_slice: %{
              "task_type" => "test",
              "semantic" => %{"intent" => "Verify behavior"},
              "success_criteria" => [%{"type" => "exit_code", "equals" => 0}]
            },
            success_criteria_results: [
              %Sykli.SuccessCriteria.Result{
                index: 0,
                type: "exit_code",
                status: :failed,
                message: "expected exit code 0, got 1",
                target: "local"
              }
            ]
          }
        ],
        overall: :failed
      }

      assert :ok = RunHistory.save(run, path: tmp_dir)
      assert {:ok, loaded} = RunHistory.load_latest(path: tmp_dir)
      [task] = loaded.tasks

      assert task.contract_slice["task_type"] == "test"
      assert task.contract_slice["semantic"]["intent"] == "Verify behavior"

      assert [%Sykli.SuccessCriteria.Result{status: :failed, target: "local"}] =
               task.success_criteria_results
    end

    test "creates latest.json symlink", %{tmp_dir: tmp_dir} do
      run = %RunHistory.Run{
        id: "test-run-2",
        timestamp: ~U[2024-01-15 10:30:00Z],
        git_ref: "abc1234",
        git_branch: "main",
        tasks: [],
        overall: :passed
      }

      :ok = RunHistory.save(run, path: tmp_dir)

      latest_path = Path.join([tmp_dir, ".sykli", "runs", "latest.json"])
      assert File.exists?(latest_path)
    end

    test "updates last_good.json when all tasks pass", %{tmp_dir: tmp_dir} do
      run = %RunHistory.Run{
        id: "test-run-3",
        timestamp: ~U[2024-01-15 10:30:00Z],
        git_ref: "abc1234",
        git_branch: "main",
        tasks: [
          %RunHistory.TaskResult{name: "test", status: :passed, duration_ms: 100}
        ],
        overall: :passed
      }

      :ok = RunHistory.save(run, path: tmp_dir)

      last_good_path = Path.join([tmp_dir, ".sykli", "runs", "last_good.json"])
      assert File.exists?(last_good_path)
    end

    test "does not update last_good.json when tasks fail", %{tmp_dir: tmp_dir} do
      run = %RunHistory.Run{
        id: "test-run-4",
        timestamp: ~U[2024-01-15 10:30:00Z],
        git_ref: "abc1234",
        git_branch: "main",
        tasks: [
          %RunHistory.TaskResult{name: "test", status: :failed, duration_ms: 100}
        ],
        overall: :failed
      }

      :ok = RunHistory.save(run, path: tmp_dir)

      last_good_path = Path.join([tmp_dir, ".sykli", "runs", "last_good.json"])
      refute File.exists?(last_good_path)
    end
  end

  describe "prune/2" do
    test "prunes old run files beyond max limit", %{tmp_dir: tmp_dir} do
      runs_dir = Path.join([tmp_dir, ".sykli", "runs"])
      File.mkdir_p!(runs_dir)

      # Create 150 fake run files
      for i <- 1..150 do
        filename =
          "2024-01-#{String.pad_leading("#{div(i, 100) + 1}", 2, "0")}-#{String.pad_leading("#{rem(i, 24)}", 2, "0")}-#{String.pad_leading("#{rem(i, 60)}", 2, "0")}-00Z.json"

        File.write!(Path.join(runs_dir, filename), "{}")
      end

      # Also create symlinks that should survive
      File.ln_s!("2024-01-02-05-29-00Z.json", Path.join(runs_dir, "latest.json"))
      File.ln_s!("2024-01-02-05-29-00Z.json", Path.join(runs_dir, "last_good.json"))

      RunHistory.prune(runs_dir, max_runs: 100)

      {:ok, files} = File.ls(runs_dir)

      run_files = Enum.filter(files, &String.match?(&1, ~r/^\d{4}-\d{2}-\d{2}.*\.json$/))
      assert length(run_files) == 100

      # Symlinks survived
      assert File.exists?(Path.join(runs_dir, "latest.json"))
      assert File.exists?(Path.join(runs_dir, "last_good.json"))
    end

    test "does nothing when under limit", %{tmp_dir: tmp_dir} do
      runs_dir = Path.join([tmp_dir, ".sykli", "runs"])
      File.mkdir_p!(runs_dir)

      for i <- 1..5 do
        File.write!(
          Path.join(runs_dir, "2024-01-15-#{String.pad_leading("#{i}", 2, "0")}-00-00Z.json"),
          "{}"
        )
      end

      RunHistory.prune(runs_dir, max_runs: 100)

      {:ok, files} = File.ls(runs_dir)
      assert length(files) == 5
    end

    test "save calls prune automatically", %{tmp_dir: tmp_dir} do
      runs_dir = Path.join([tmp_dir, ".sykli", "runs"])
      File.mkdir_p!(runs_dir)

      # Pre-populate with 5 files
      for i <- 1..5 do
        File.write!(
          Path.join(runs_dir, "2024-01-15-#{String.pad_leading("#{i}", 2, "0")}-00-00Z.json"),
          "{}"
        )
      end

      # Save a new run with max_runs: 3
      run = %RunHistory.Run{
        id: "new-run",
        timestamp: ~U[2024-01-16 10:00:00Z],
        git_ref: "abc123",
        git_branch: "main",
        tasks: [],
        overall: :passed
      }

      :ok = RunHistory.save(run, path: tmp_dir, max_runs: 3)

      {:ok, files} = File.ls(runs_dir)
      run_files = Enum.filter(files, &String.match?(&1, ~r/^\d{4}-\d{2}-\d{2}.*\.json$/))
      assert length(run_files) == 3
    end
  end

  describe "execution history contract slices" do
    test "Sykli.run persists task contract slice and criteria results", %{tmp_dir: tmp_dir} do
      json =
        Jason.encode!(%{
          "version" => "3",
          "tasks" => [
            %{
              "name" => "test",
              "command" => "echo ok",
              "task_type" => "test",
              "semantic" => %{"intent" => "Verify behavior", "covers" => ["lib/**"]},
              "success_criteria" => [%{"type" => "exit_code", "equals" => 0}]
            }
          ]
        })

      File.write!(Path.join(tmp_dir, "sykli.exs"), "IO.puts(#{inspect(json)})")

      assert {:ok, _results} = Sykli.run(tmp_dir)
      assert {:ok, run} = RunHistory.load_latest(path: tmp_dir)
      [task] = run.tasks

      assert task.contract_slice["task_type"] == "test"
      assert task.contract_slice["semantic"]["intent"] == "Verify behavior"
      assert task.contract_slice["success_criteria"] == [%{"type" => "exit_code", "equals" => 0}]

      assert [%Sykli.SuccessCriteria.Result{status: :passed, type: "exit_code"}] =
               task.success_criteria_results
    end
  end

  describe "load_latest/1" do
    test "returns latest run", %{tmp_dir: tmp_dir} do
      run = %RunHistory.Run{
        id: "test-run-5",
        timestamp: ~U[2024-01-15 10:30:00Z],
        git_ref: "abc1234",
        git_branch: "main",
        tasks: [],
        overall: :passed
      }

      :ok = RunHistory.save(run, path: tmp_dir)

      assert {:ok, loaded} = RunHistory.load_latest(path: tmp_dir)
      assert loaded.id == "test-run-5"
      assert loaded.git_ref == "abc1234"
    end

    test "loads old run history without contract slices", %{tmp_dir: tmp_dir} do
      runs_dir = Path.join([tmp_dir, ".sykli", "runs"])
      File.mkdir_p!(runs_dir)

      File.write!(
        Path.join(runs_dir, "latest.json"),
        Jason.encode!(%{
          "id" => "old-run",
          "timestamp" => "2024-01-15T10:30:00Z",
          "git_ref" => "abc1234",
          "git_branch" => "main",
          "overall" => "failed",
          "tasks" => [
            %{
              "name" => "test",
              "status" => "failed",
              "duration_ms" => 100,
              "cached" => false,
              "streak" => 0,
              "error" => "task_failed: task failed"
            }
          ]
        })
      )

      assert {:ok, loaded} = RunHistory.load_latest(path: tmp_dir)
      [task] = loaded.tasks
      assert task.contract_slice == nil
      assert task.success_criteria_results == []
    end

    test "returns error when no runs exist", %{tmp_dir: tmp_dir} do
      assert {:error, :no_runs} = RunHistory.load_latest(path: tmp_dir)
    end
  end

  describe "load_last_good/1" do
    test "returns last passing run", %{tmp_dir: tmp_dir} do
      # First save a passing run
      good_run = %RunHistory.Run{
        id: "good-run",
        timestamp: ~U[2024-01-15 10:00:00Z],
        git_ref: "good1234",
        git_branch: "main",
        tasks: [%RunHistory.TaskResult{name: "test", status: :passed, duration_ms: 100}],
        overall: :passed
      }

      :ok = RunHistory.save(good_run, path: tmp_dir)

      # Then save a failing run
      bad_run = %RunHistory.Run{
        id: "bad-run",
        timestamp: ~U[2024-01-15 11:00:00Z],
        git_ref: "bad1234",
        git_branch: "main",
        tasks: [%RunHistory.TaskResult{name: "test", status: :failed, duration_ms: 100}],
        overall: :failed
      }

      :ok = RunHistory.save(bad_run, path: tmp_dir)

      # last_good should still be the good run
      assert {:ok, loaded} = RunHistory.load_last_good(path: tmp_dir)
      assert loaded.id == "good-run"
      assert loaded.git_ref == "good1234"
    end

    test "returns error when no passing runs exist", %{tmp_dir: tmp_dir} do
      assert {:error, :no_passing_runs} = RunHistory.load_last_good(path: tmp_dir)
    end
  end

  describe "list/1" do
    test "returns runs in reverse chronological order", %{tmp_dir: tmp_dir} do
      # Save multiple runs
      for i <- 1..3 do
        run = %RunHistory.Run{
          id: "run-#{i}",
          timestamp: DateTime.add(~U[2024-01-15 10:00:00Z], i * 3600),
          git_ref: "ref#{i}",
          git_branch: "main",
          tasks: [],
          overall: :passed
        }

        :ok = RunHistory.save(run, path: tmp_dir)
      end

      assert {:ok, runs} = RunHistory.list(path: tmp_dir, limit: 10)
      assert length(runs) == 3

      # Most recent first
      [first | _] = runs
      assert first.id == "run-3"
    end

    test "respects limit option", %{tmp_dir: tmp_dir} do
      for i <- 1..5 do
        run = %RunHistory.Run{
          id: "run-#{i}",
          timestamp: DateTime.add(~U[2024-01-15 10:00:00Z], i * 3600),
          git_ref: "ref#{i}",
          git_branch: "main",
          tasks: [],
          overall: :passed
        }

        :ok = RunHistory.save(run, path: tmp_dir)
      end

      assert {:ok, runs} = RunHistory.list(path: tmp_dir, limit: 2)
      assert length(runs) == 2
    end
  end

  describe "list_by_work_item/2" do
    test "returns associated runs in deterministic recent-first order", %{tmp_dir: tmp_dir} do
      for {id, work_item_id, hour} <- [
            {"run-1", "work_001", 1},
            {"run-2", "work_002", 2},
            {"run-3", "work_001", 3}
          ] do
        run = %RunHistory.Run{
          id: id,
          timestamp: DateTime.add(~U[2024-01-15 10:00:00Z], hour * 3600),
          git_ref: "ref#{hour}",
          git_branch: "main",
          work_item_id: work_item_id,
          contract_hash: "sha256:#{hour}",
          tasks: [],
          overall: :passed
        }

        :ok = RunHistory.save(run, path: tmp_dir)
      end

      assert {:ok, runs} = RunHistory.list_by_work_item("work_001", path: tmp_dir)
      assert Enum.map(runs, & &1.id) == ["run-3", "run-1"]
    end

    test "filters before applying limit", %{tmp_dir: tmp_dir} do
      for {id, work_item_id, hour} <- [
            {"run-1", "work_001", 1},
            {"run-2", "work_002", 2},
            {"run-3", "work_002", 3},
            {"run-4", "work_001", 4}
          ] do
        run = %RunHistory.Run{
          id: id,
          timestamp: DateTime.add(~U[2024-01-15 10:00:00Z], hour * 3600),
          git_ref: "ref#{hour}",
          git_branch: "main",
          work_item_id: work_item_id,
          contract_hash: "sha256:#{hour}",
          tasks: [],
          overall: :passed
        }

        :ok = RunHistory.save(run, path: tmp_dir)
      end

      assert {:ok, runs} = RunHistory.list_by_work_item("work_001", path: tmp_dir, limit: 2)
      assert Enum.map(runs, & &1.id) == ["run-4", "run-1"]
    end

    test "rejects invalid work item id before listing", %{tmp_dir: tmp_dir} do
      assert {:error, {:invalid_work_item_id, "../escape"}} =
               RunHistory.list_by_work_item("../escape", path: tmp_dir)
    end
  end

  describe "get/2" do
    test "returns the run matching the id", %{tmp_dir: tmp_dir} do
      for i <- 1..3 do
        run = %RunHistory.Run{
          id: "run-#{i}",
          timestamp: DateTime.add(~U[2024-01-15 10:00:00Z], i * 3600),
          git_ref: "ref#{i}",
          git_branch: "main",
          tasks: [],
          overall: :passed
        }

        :ok = RunHistory.save(run, path: tmp_dir)
      end

      assert {:ok, run} = RunHistory.get("run-2", path: tmp_dir)
      assert run.id == "run-2"
      assert run.git_ref == "ref2"
    end

    test "returns {:error, :not_found} for an unknown id", %{tmp_dir: tmp_dir} do
      run = %RunHistory.Run{
        id: "run-1",
        timestamp: ~U[2024-01-15 10:00:00Z],
        git_ref: "ref1",
        git_branch: "main",
        tasks: [],
        overall: :passed
      }

      :ok = RunHistory.save(run, path: tmp_dir)

      assert {:error, :not_found} = RunHistory.get("missing", path: tmp_dir)
    end

    test "returns {:error, :not_found} when runs directory doesn't exist", %{tmp_dir: tmp_dir} do
      assert {:error, :not_found} = RunHistory.get("run-1", path: tmp_dir)
    end

    test "skips corrupt manifests while searching for other runs", %{tmp_dir: tmp_dir} do
      run = %RunHistory.Run{
        id: "run-valid",
        timestamp: ~U[2024-01-15 10:00:00Z],
        git_ref: "ref1",
        git_branch: "main",
        tasks: [],
        overall: :passed
      }

      :ok = RunHistory.save(run, path: tmp_dir)

      # Newer than the valid manifest, so it is scanned first.
      runs_dir = Path.join([tmp_dir, ".sykli", "runs"])
      File.write!(Path.join(runs_dir, "2024-01-16T00-00-00Z.json"), "{garbage")

      assert {:ok, found} = RunHistory.get("run-valid", path: tmp_dir)
      assert found.id == "run-valid"
    end

    test "returns {:error, :corrupt} when the matching manifest fails decoding",
         %{tmp_dir: tmp_dir} do
      runs_dir = Path.join([tmp_dir, ".sykli", "runs"])
      File.mkdir_p!(runs_dir)

      corrupt =
        Jason.encode!(%{
          "id" => "run-bad",
          "timestamp" => "2024-01-15T10:00:00Z",
          "git_ref" => "ref1",
          "git_branch" => "main",
          "tasks" => [],
          "overall" => "no_such_status_atom_run_history_test"
        })

      File.write!(Path.join(runs_dir, "2024-01-15T10-00-00Z.json"), corrupt)

      assert {:error, :corrupt} = RunHistory.get("run-bad", path: tmp_dir)
    end
  end

  describe "list/1 error handling" do
    test "returns {:error, reason} for non-enoent filesystem errors", %{tmp_dir: tmp_dir} do
      # Create a file where the runs directory should be — File.ls on a file returns :enotdir
      runs_dir = Path.join([tmp_dir, ".sykli", "runs"])
      File.mkdir_p!(Path.join(tmp_dir, ".sykli"))
      File.write!(runs_dir, "not a directory")

      assert {:error, :enotdir} = RunHistory.list(path: tmp_dir)
    end

    test "returns {:ok, []} when runs directory doesn't exist", %{tmp_dir: tmp_dir} do
      assert {:ok, []} = RunHistory.list(path: tmp_dir)
    end
  end

  describe "Run struct" do
    test "has required fields" do
      run = %RunHistory.Run{
        id: "test",
        timestamp: DateTime.utc_now(),
        git_ref: "abc123",
        git_branch: "main",
        tasks: [],
        overall: :passed
      }

      assert run.id == "test"
      assert run.overall == :passed
    end
  end

  describe "TaskResult struct" do
    test "has required fields" do
      result = %RunHistory.TaskResult{
        name: "test",
        status: :passed,
        duration_ms: 1234
      }

      assert result.name == "test"
      assert result.status == :passed
      assert result.duration_ms == 1234
    end

    test "has optional fields" do
      result = %RunHistory.TaskResult{
        name: "build",
        status: :failed,
        duration_ms: 567,
        cached: false,
        error: "exit code 1",
        inputs: ["**/*.go"],
        likely_cause: ["src/main.go"]
      }

      assert result.error == "exit code 1"
      assert result.likely_cause == ["src/main.go"]
    end
  end
end
