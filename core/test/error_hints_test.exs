defmodule Sykli.ErrorHintsTest do
  use ExUnit.Case

  alias Sykli.ErrorHints

  describe "exit code hints" do
    test "exit 1 - generic error" do
      hint = ErrorHints.for_exit_code(1)
      # Exit 1 is too generic to give a useful hint
      assert hint == nil
    end

    test "exit 126 - not executable" do
      hint = ErrorHints.for_exit_code(126)
      assert hint =~ "chmod" or hint =~ "executable"
    end

    test "exit 127 - command not found" do
      hint = ErrorHints.for_exit_code(127)
      assert hint =~ "not found" or hint =~ "install" or hint =~ "PATH"
    end

    test "exit 128+9 (137) - killed by SIGKILL (OOM)" do
      hint = ErrorHints.for_exit_code(137)
      assert hint =~ "killed" or hint =~ "memory" or hint =~ "OOM"
    end

    test "exit 128+15 (143) - killed by SIGTERM" do
      hint = ErrorHints.for_exit_code(143)
      assert hint =~ "terminated" or hint =~ "SIGTERM"
    end
  end

  describe "output pattern hints" do
    test "command not found in output" do
      output = "bash: go: command not found"
      hint = ErrorHints.for_output(output)
      assert hint =~ "install" or hint =~ "PATH"
    end

    test "permission denied" do
      output = "permission denied: ./script.sh"
      hint = ErrorHints.for_output(output)
      assert hint =~ "chmod" or hint =~ "permission"
    end

    test "no such file or directory" do
      output = "no such file or directory: ./missing.sh"
      hint = ErrorHints.for_output(output)
      assert hint =~ "exist" or hint =~ "path"
    end

    test "connection refused" do
      output = "dial tcp 127.0.0.1:5432: connect: connection refused"
      hint = ErrorHints.for_output(output)
      assert hint =~ "service" or hint =~ "running" or hint =~ "port"
    end

    test "docker image not found" do
      output = "Unable to find image 'nonexistent:latest' locally"
      hint = ErrorHints.for_output(output)
      assert hint =~ "image" or hint =~ "pull" or hint =~ "exist"
    end

    test "go module error" do
      output = "go: cannot find module providing package github.com/foo/bar"
      hint = ErrorHints.for_output(output)
      assert hint =~ "go mod" or hint =~ "module"
    end

    test "npm module not found" do
      output = "Cannot find module 'express'"
      hint = ErrorHints.for_output(output)
      assert hint =~ "npm install" or hint =~ "module"
    end

    test "rust cargo error" do
      output = "error[E0432]: unresolved import `foo`"
      hint = ErrorHints.for_output(output)
      assert hint =~ "Cargo.toml" or hint =~ "dependency" or hint =~ "import"
    end

    test "timeout" do
      output = "context deadline exceeded"
      hint = ErrorHints.for_output(output)
      assert hint =~ "timeout" or hint =~ "slow"
    end

    test "no hint for unknown output" do
      output = "some random output that doesn't match patterns"
      hint = ErrorHints.for_output(output)
      assert hint == nil
    end
  end

  describe "combined hints" do
    test "combines exit code and output hints" do
      hints = ErrorHints.get_hints(127, "bash: go: command not found")
      assert is_list(hints)
      assert length(hints) >= 1
    end
  end
end
