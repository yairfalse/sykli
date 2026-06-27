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

  test "masks resolved secret values in the output summary" do
    secret = "super-secret-token-value"

    result = %TaskResult{
      name: "deploy",
      status: :passed,
      duration_ms: 5,
      output: "connecting with #{secret} ...\ndone",
      command: "deploy",
      secret_values: [secret]
    }

    summary = CheckRunFormatter.format(result).summary

    refute summary =~ secret
    assert summary =~ "***MASKED***"
    assert summary =~ "done"
  end

  test "masks secret values that appear in error output" do
    secret = "another-secret-9999"

    result = %TaskResult{
      name: "publish",
      status: :errored,
      duration_ms: 7,
      error: Sykli.Error.internal("auth failed using #{secret}"),
      output: nil,
      command: "publish",
      secret_values: [secret]
    }

    summary = CheckRunFormatter.format(result).summary

    refute summary =~ secret
    assert summary =~ "Infrastructure failure"
  end

  test "leaves output untouched when there are no secrets" do
    result = %TaskResult{
      name: "build",
      status: :failed,
      duration_ms: 3,
      output: "compile error on line 12",
      command: "build",
      secret_values: []
    }

    summary = CheckRunFormatter.format(result).summary

    assert summary =~ "compile error on line 12"
    refute summary =~ "***MASKED***"
  end

  defp conclusion(status) do
    CheckRunFormatter.conclusion(%TaskResult{name: "task", status: status, duration_ms: 1})
  end
end
