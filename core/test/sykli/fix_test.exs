defmodule Sykli.FixTest do
  use ExUnit.Case, async: true

  alias Sykli.Fix

  describe "analyze/2" do
    test "returns :no_occurrence when no data exists" do
      assert {:error, :no_occurrence} = Fix.analyze("/nonexistent/path")
    end

    test "returns :nothing_to_fix when last run passed" do
      dir =
        setup_occurrence_dir(%{
          "outcome" => "success",
          "id" => "run-123",
          "data" => %{"tasks" => []}
        })

      assert {:ok, %{status: :nothing_to_fix}} = Fix.analyze(dir)
    end

    test "analyzes failed tasks" do
      dir =
        setup_occurrence_dir(%{
          "outcome" => "failure",
          "id" => "run-456",
          "timestamp" => "2026-03-06T10:00:00Z",
          "error" => %{
            "what_failed" => "task 'test' failed",
            "suggested_fix" => "fix the test"
          },
          "reasoning" => %{
            "summary" => "test failed",
            "confidence" => 0.8
          },
          "data" => %{
            "git" => %{"sha" => "abc1234", "branch" => "main"},
            "summary" => %{"passed" => 1, "failed" => 1},
            "tasks" => [
              %{
                "name" => "lint",
                "status" => "passed",
                "command" => "mix credo",
                "duration_ms" => 500
              },
              %{
                "name" => "test",
                "status" => "failed",
                "command" => "mix test",
                "duration_ms" => 1200,
                "error" => %{
                  "code" => "task_failed",
                  "message" => "test suite failed",
                  "exit_code" => 1,
                  "hints" => ["fix the failing assertion"]
                },
                "history" => %{
                  "pass_count" => 9,
                  "total_count" => 10,
                  "current_streak" => 0,
                  "flaky" => false
                }
              }
            ],
            "error_details" => [
              %{
                "task" => "test",
                "exit_code" => 1,
                "locations" => [
                  %{"file" => "test/auth_test.exs", "line" => 42, "message" => "assertion failed"}
                ]
              }
            ]
          }
        })

      assert {:ok, result} = Fix.analyze(dir)
      assert result.status == :failure_found
      assert result.summary["failed_count"] == 1
      assert result.summary["total_count"] == 2

      [task] = result.tasks
      assert task["name"] == "test"
      assert task["command"] == "mix test"
      assert task["exit_code"] == 1
      assert [loc] = task["locations"]
      assert loc["file"] == "test/auth_test.exs"
      assert loc["line"] == 42
      assert loc["message"] == "assertion failed"
    end

    test "filters by task name" do
      dir =
        setup_occurrence_dir(%{
          "outcome" => "failure",
          "id" => "run-789",
          "data" => %{
            "tasks" => [
              %{"name" => "lint", "status" => "failed", "command" => "mix credo"},
              %{"name" => "test", "status" => "failed", "command" => "mix test"}
            ],
            "error_details" => []
          }
        })

      assert {:ok, result} = Fix.analyze(dir, task: "lint")
      assert length(result.tasks) == 1
      assert hd(result.tasks)["name"] == "lint"
    end

    test "returns :no_failures when filter matches no failed tasks" do
      dir =
        setup_occurrence_dir(%{
          "outcome" => "failure",
          "id" => "run-999",
          "data" => %{
            "tasks" => [
              %{"name" => "test", "status" => "failed", "command" => "mix test"}
            ],
            "error_details" => []
          }
        })

      assert {:error, :no_failures} = Fix.analyze(dir, task: "nonexistent")
    end

    test "detects regression" do
      dir =
        setup_occurrence_dir(%{
          "outcome" => "failure",
          "id" => "run-reg",
          "data" => %{
            "tasks" => [
              %{"name" => "test", "status" => "failed", "command" => "mix test"}
            ],
            "error_details" => [],
            "regression" => %{"is_new_failure" => true, "tasks" => ["test"]}
          }
        })

      assert {:ok, result} = Fix.analyze(dir)
      assert hd(result.tasks)["regression"] == true
    end
  end

  describe "read_source_lines/3" do
    test "reads source with context around target line" do
      file = tmp_file("fix_test_source", ".ex")
      content = Enum.map_join(1..20, "\n", fn n -> "line #{n}" end)
      File.write!(file, content)

      lines = Fix.read_source_lines(file, 10, 2)

      assert length(lines) == 5
      assert Enum.any?(lines, &String.contains?(&1, ">> "))
      assert Enum.any?(lines, &String.contains?(&1, "line 10"))
      assert Enum.any?(lines, &String.contains?(&1, "line 8"))
      assert Enum.any?(lines, &String.contains?(&1, "line 12"))
    end

    test "handles file not found" do
      assert Fix.read_source_lines("/no/such/file.ex", 1, 5) == nil
    end

    test "handles edge lines (line 1)" do
      file = tmp_file("fix_test_edge", ".ex")
      content = Enum.map_join(1..5, "\n", fn n -> "line #{n}" end)
      File.write!(file, content)

      lines = Fix.read_source_lines(file, 1, 3)
      assert hd(lines) =~ ">>"
      assert length(lines) == 4
    end
  end

  describe "to_map/1" do
    test "formats nothing_to_fix" do
      result = Fix.to_map(%{status: :nothing_to_fix, run_id: "abc"})
      assert result["status"] == "nothing_to_fix"
    end

    test "formats failure_found" do
      result =
        Fix.to_map(%{
          status: :failure_found,
          summary: %{"failed_count" => 1},
          tasks: [%{"name" => "test"}],
          diff_since_last_good: nil
        })

      assert result["status"] == "failure_found"
      assert result["summary"]["failed_count"] == 1
      assert length(result["tasks"]) == 1
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp setup_occurrence_dir(occurrence) do
    dir = Path.join(System.tmp_dir!(), "sykli_fix_test_#{:rand.uniform(100_000)}")
    sykli_dir = Path.join(dir, ".sykli")
    File.mkdir_p!(sykli_dir)

    json = Jason.encode!(occurrence)
    File.write!(Path.join(sykli_dir, "occurrence.json"), json)

    on_exit(fn -> File.rm_rf!(dir) end)

    dir
  end

  defp tmp_file(prefix, ext) do
    dir = System.tmp_dir!()
    file = Path.join(dir, "#{prefix}_#{:rand.uniform(100_000)}#{ext}")
    on_exit(fn -> File.rm(file) end)
    file
  end
end
