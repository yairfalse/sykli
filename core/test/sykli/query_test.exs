defmodule Sykli.QueryTest do
  use ExUnit.Case, async: true

  alias Sykli.Query

  describe "classify/1" do
    # Coverage queries
    test "what tests cover <pattern>" do
      assert Query.classify("what tests cover auth") == {:coverage, "auth"}
    end

    test "what covers <pattern>" do
      assert Query.classify("what covers src/api/*") == {:coverage, "src/api/*"}
    end

    test "coverage for <pattern>" do
      assert Query.classify("coverage for lib/core") == {:coverage, "lib/core"}
    end

    test "covers <pattern>" do
      assert Query.classify("covers auth") == {:coverage, "auth"}
    end

    # Failure queries
    test "why did <task> fail" do
      assert Query.classify("why did build fail") == {:failure, "build", :latest}
    end

    test "why did <task> fail yesterday" do
      assert Query.classify("why did test fail yesterday") == {:failure, "test", :yesterday}
    end

    test "why did <task> fail today" do
      assert Query.classify("why did e2e fail today") == {:failure, "e2e", :today}
    end

    # Last pass queries
    test "when did <task> last pass" do
      assert Query.classify("when did build last pass") == {:last_pass, "build"}
    end

    test "when did <task> last succeed" do
      assert Query.classify("when did test last succeed") == {:last_pass, "test"}
    end

    # Health queries
    test "what's flaky" do
      assert Query.classify("what's flaky") == {:health, :flaky}
    end

    test "whats flaky" do
      assert Query.classify("whats flaky") == {:health, :flaky}
    end

    test "flaky tasks" do
      assert Query.classify("flaky tasks") == {:health, :flaky}
    end

    test "flaky" do
      assert Query.classify("flaky") == {:health, :flaky}
    end

    test "failure rate" do
      assert Query.classify("failure rate") == {:health, :failure_rate}
    end

    test "success rate" do
      assert Query.classify("success rate") == {:health, :failure_rate}
    end

    test "health" do
      assert Query.classify("health") == {:health, :summary}
    end

    test "slowest tasks" do
      assert Query.classify("slowest tasks") == {:health, :slowest}
    end

    test "slowest" do
      assert Query.classify("slowest") == {:health, :slowest}
    end

    # Task queries
    test "critical tasks" do
      assert Query.classify("critical tasks") == {:tasks, :critical, nil}
    end

    test "critical" do
      assert Query.classify("critical") == {:tasks, :critical, nil}
    end

    test "dependencies of <task>" do
      assert Query.classify("dependencies of build") == {:tasks, :deps, "build"}
    end

    test "deps of <task>" do
      assert Query.classify("deps of test") == {:tasks, :deps, "test"}
    end

    test "what depends on <task>" do
      assert Query.classify("what depends on lint") == {:tasks, :dependents, "lint"}
    end

    test "dependents of <task>" do
      assert Query.classify("dependents of build") == {:tasks, :dependents, "build"}
    end

    test "task <name>" do
      assert Query.classify("task core:test") == {:tasks, :details, "core:test"}
    end

    # Run queries
    test "last run" do
      assert Query.classify("last run") == {:runs, :latest}
    end

    test "last good run" do
      assert Query.classify("last good run") == {:runs, :last_good}
    end

    test "last passing run" do
      assert Query.classify("last passing run") == {:runs, :last_good}
    end

    test "runs today" do
      assert Query.classify("runs today") == {:runs, :today}
    end

    test "recent runs" do
      assert Query.classify("recent runs") == {:runs, :recent}
    end

    # Unknown
    test "unknown query" do
      assert Query.classify("how's the weather") == :unknown
    end

    test "empty string" do
      assert Query.classify("") == :unknown
    end
  end

  describe "classify/1 normalizes input" do
    test "execute normalizes case" do
      # execute/2 lowercases before classify
      normalized = "What Tests Cover Auth" |> String.trim() |> String.downcase()
      assert Query.classify(normalized) == {:coverage, "auth"}
    end

    test "trims whitespace" do
      normalized = "  flaky tasks  " |> String.trim() |> String.downcase()
      assert Query.classify(normalized) == {:health, :flaky}
    end
  end

  describe "format_error/1" do
    test "unknown query" do
      msg = Query.format_error({:unknown_query, "gibberish"})
      assert msg =~ "Unknown query"
      assert msg =~ "gibberish"
    end

    test "task not found" do
      msg = Query.format_error({:task_not_found, "nonexistent"})
      assert msg =~ "nonexistent"
      assert msg =~ "not found"
    end

    test "no runs" do
      msg = Query.format_error(:no_runs)
      assert msg =~ "No run history"
    end
  end
end
