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

  describe "calculate_streak/2" do
    test "calculates consecutive pass streak", %{tmp_dir: tmp_dir} do
      # Save 3 runs where "test" passed each time
      for i <- 1..3 do
        run = %RunHistory.Run{
          id: "run-#{i}",
          timestamp: DateTime.add(~U[2024-01-15 10:00:00Z], i * 3600),
          git_ref: "ref#{i}",
          git_branch: "main",
          tasks: [%RunHistory.TaskResult{name: "test", status: :passed, duration_ms: 100}],
          overall: :passed
        }

        :ok = RunHistory.save(run, path: tmp_dir)
      end

      # Calculate streak for "test" task
      assert {:ok, 3} = RunHistory.calculate_streak("test", path: tmp_dir)
    end

    test "streak resets on failure", %{tmp_dir: tmp_dir} do
      # 2 passing runs
      for i <- 1..2 do
        run = %RunHistory.Run{
          id: "pass-#{i}",
          timestamp: DateTime.add(~U[2024-01-15 10:00:00Z], i * 3600),
          git_ref: "ref#{i}",
          git_branch: "main",
          tasks: [%RunHistory.TaskResult{name: "test", status: :passed, duration_ms: 100}],
          overall: :passed
        }

        :ok = RunHistory.save(run, path: tmp_dir)
      end

      # 1 failing run
      fail_run = %RunHistory.Run{
        id: "fail-1",
        timestamp: DateTime.add(~U[2024-01-15 10:00:00Z], 3 * 3600),
        git_ref: "fail-ref",
        git_branch: "main",
        tasks: [%RunHistory.TaskResult{name: "test", status: :failed, duration_ms: 100}],
        overall: :failed
      }

      :ok = RunHistory.save(fail_run, path: tmp_dir)

      # 1 more passing run
      new_pass = %RunHistory.Run{
        id: "pass-3",
        timestamp: DateTime.add(~U[2024-01-15 10:00:00Z], 4 * 3600),
        git_ref: "new-ref",
        git_branch: "main",
        tasks: [%RunHistory.TaskResult{name: "test", status: :passed, duration_ms: 100}],
        overall: :passed
      }

      :ok = RunHistory.save(new_pass, path: tmp_dir)

      # Streak should be 1 (only the latest pass, after the failure reset)
      assert {:ok, 1} = RunHistory.calculate_streak("test", path: tmp_dir)
    end

    test "returns 0 for unknown task", %{tmp_dir: tmp_dir} do
      assert {:ok, 0} = RunHistory.calculate_streak("nonexistent", path: tmp_dir)
    end
  end

  describe "likely_cause/3" do
    test "returns intersection of changed files and task inputs", %{tmp_dir: tmp_dir} do
      # Save a good run
      good_run = %RunHistory.Run{
        id: "good-run",
        timestamp: ~U[2024-01-15 10:00:00Z],
        git_ref: "good1234",
        git_branch: "main",
        tasks: [
          %RunHistory.TaskResult{
            name: "build",
            status: :passed,
            duration_ms: 100,
            inputs: ["src/**/*.go", "go.mod"]
          }
        ],
        overall: :passed
      }

      :ok = RunHistory.save(good_run, path: tmp_dir)

      # Mock changed files since last good
      changed_files = MapSet.new(["src/main.go", "README.md", "docs/guide.md"])

      # The build task's inputs intersected with changes
      task_inputs = MapSet.new(["src/main.go", "src/lib.go", "go.mod"])

      likely = RunHistory.likely_cause(changed_files, task_inputs)

      assert MapSet.equal?(likely, MapSet.new(["src/main.go"]))
    end

    test "returns empty set when no intersection", %{tmp_dir: _tmp_dir} do
      changed_files = MapSet.new(["README.md", "docs/guide.md"])
      task_inputs = MapSet.new(["src/main.go", "src/lib.go"])

      likely = RunHistory.likely_cause(changed_files, task_inputs)

      assert MapSet.size(likely) == 0
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
