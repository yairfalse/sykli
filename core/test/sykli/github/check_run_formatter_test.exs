defmodule Sykli.GitHub.CheckRunFormatterTest do
  use ExUnit.Case, async: true

  alias Sykli.Executor.TaskResult
  alias Sykli.GitHub.CheckRunFormatter

  test "maps Sykli task statuses to GitHub conclusions" do
    assert conclusion(:passed) == "success"
    assert conclusion(:failed) == "failure"
    assert conclusion(:errored) == "failure"
    assert conclusion(:cached) == "success"
    assert conclusion(:skipped) == "skipped"
    assert conclusion(:blocked) == "cancelled"
  end

  test "formats errored results as infrastructure failures" do
    result = %TaskResult{
      name: "setup",
      status: :errored,
      duration_ms: 12,
      error: Sykli.Error.internal("runtime unavailable"),
      output: nil,
      command: "setup"
    }

    formatted = CheckRunFormatter.format(result)

    assert formatted.title == "setup: errored"
    assert formatted.summary =~ "Infrastructure failure"
    assert formatted.summary =~ "runtime unavailable"
  end

  test "cache hit titles are explicit" do
    result = %TaskResult{name: "deps", status: :cached, duration_ms: 1}

    assert CheckRunFormatter.format(result).title == "deps: cached (cache hit)"
  end

  defp conclusion(status) do
    CheckRunFormatter.conclusion(%TaskResult{name: "task", status: status, duration_ms: 1})
  end
end
