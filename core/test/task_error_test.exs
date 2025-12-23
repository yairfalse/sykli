defmodule Sykli.TaskErrorTest do
  use ExUnit.Case

  alias Sykli.TaskError

  describe "TaskError.new/1" do
    test "creates error with all required fields" do
      error = TaskError.new(
        task: "build",
        command: "go build ./...",
        exit_code: 1,
        output: "main.go:10: undefined: foo",
        duration_ms: 1234
      )

      assert error.task == "build"
      assert error.command == "go build ./..."
      assert error.exit_code == 1
      assert error.output == "main.go:10: undefined: foo"
      assert error.duration_ms == 1234
    end

    test "generates hints automatically" do
      error = TaskError.new(
        task: "test",
        command: "go test ./...",
        exit_code: 127,
        output: "bash: go: command not found",
        duration_ms: 100
      )

      assert length(error.hints) >= 1
      assert Enum.any?(error.hints, &(&1 =~ "PATH" or &1 =~ "install"))
    end
  end

  describe "TaskError.format/1" do
    test "includes task name and exit code" do
      error = TaskError.new(
        task: "lint",
        command: "golangci-lint run",
        exit_code: 1,
        output: "main.go:5: error",
        duration_ms: 500
      )

      formatted = TaskError.format(error)
      assert formatted =~ "lint"
      assert formatted =~ "exit 1"
    end

    test "includes command that was run" do
      error = TaskError.new(
        task: "build",
        command: "cargo build --release",
        exit_code: 101,
        output: "error[E0432]: unresolved import",
        duration_ms: 2000
      )

      formatted = TaskError.format(error)
      assert formatted =~ "cargo build --release"
    end

    test "includes last lines of output" do
      long_output = """
      Compiling foo v0.1.0
      Compiling bar v0.2.0
      error[E0432]: unresolved import `baz`
       --> src/main.rs:1:5
        |
      1 | use baz::Qux;
        |     ^^^ could not find `baz` in the crate root
      """

      error = TaskError.new(
        task: "build",
        command: "cargo build",
        exit_code: 101,
        output: long_output,
        duration_ms: 3000
      )

      formatted = TaskError.format(error)
      assert formatted =~ "unresolved import"
      assert formatted =~ "could not find"
    end

    test "includes hints when available" do
      error = TaskError.new(
        task: "test",
        command: "npm test",
        exit_code: 1,
        output: "Cannot find module 'jest'",
        duration_ms: 100
      )

      formatted = TaskError.format(error)
      assert formatted =~ "npm install" or formatted =~ "module"
    end

    test "includes duration" do
      error = TaskError.new(
        task: "build",
        command: "make",
        exit_code: 2,
        output: "error",
        duration_ms: 45_000
      )

      formatted = TaskError.format(error)
      assert formatted =~ "45" or formatted =~ "45.0s"
    end
  end

  describe "TaskError.format/2 options" do
    test "max_lines limits output" do
      lines = Enum.map(1..20, &"line #{&1}") |> Enum.join("\n")

      error = TaskError.new(
        task: "test",
        command: "test",
        exit_code: 1,
        output: lines,
        duration_ms: 100
      )

      formatted = TaskError.format(error, max_lines: 5)
      # Should show last 5 lines
      assert formatted =~ "line 20"
      assert formatted =~ "line 16"
      refute formatted =~ "line 10"
    end

    test "no_color disables ANSI codes" do
      error = TaskError.new(
        task: "build",
        command: "make",
        exit_code: 1,
        output: "error",
        duration_ms: 100
      )

      formatted = TaskError.format(error, no_color: true)
      refute formatted =~ "\e["
    end
  end
end
