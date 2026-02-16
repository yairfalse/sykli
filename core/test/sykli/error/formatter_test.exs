defmodule Sykli.Error.FormatterTest do
  use ExUnit.Case, async: true

  alias Sykli.Error
  alias Sykli.Error.Formatter

  describe "format_full locations" do
    test "includes locations in box format" do
      error = %Error{
        code: "task_failed",
        type: :execution,
        message: "task 'test' failed",
        task: "test",
        step: :run,
        command: "go test ./...",
        output: nil,
        exit_code: 1,
        hints: [],
        notes: [],
        locations: [
          %{file: "main.go", line: 15, column: 3, message: "undefined: Foo"}
        ]
      }

      output = Formatter.format(error, no_color: true)
      assert String.contains?(output, "--> main.go:15")
      assert String.contains?(output, "undefined: Foo")
    end

    test "includes multiple locations in box format" do
      error = %Error{
        code: "task_failed",
        type: :execution,
        message: "task 'build' failed",
        task: "build",
        step: :run,
        command: nil,
        output: nil,
        exit_code: 1,
        hints: [],
        notes: [],
        locations: [
          %{file: "a.go", line: 10, column: nil, message: nil},
          %{file: "b.go", line: 20, column: nil, message: "error here"}
        ]
      }

      output = Formatter.format(error, no_color: true)
      assert String.contains?(output, "--> a.go:10")
      assert String.contains?(output, "--> b.go:20")
      assert String.contains?(output, "error here")
    end

    test "skips locations section when empty" do
      error = %Error{
        code: "task_failed",
        type: :execution,
        message: "task 'test' failed",
        task: "test",
        step: :run,
        command: nil,
        output: nil,
        exit_code: nil,
        hints: ["fix the code"],
        notes: [],
        locations: []
      }

      output = Formatter.format(error, no_color: true)
      refute String.contains?(output, "-->")
      assert String.contains?(output, "fix the code")
    end
  end

  describe "format_simple locations" do
    test "includes locations in simple format" do
      error = %Error{
        code: "task_failed",
        type: :execution,
        message: "task 'test' failed",
        task: "test",
        step: :run,
        command: nil,
        output: nil,
        exit_code: 1,
        hints: [],
        notes: [],
        locations: [
          %{file: "main.go", line: 15, column: 3, message: "undefined: Foo"}
        ]
      }

      output = Formatter.format_simple(error, no_color: true)
      assert String.contains?(output, "--> main.go:15")
      assert String.contains?(output, "undefined: Foo")
    end
  end
end
