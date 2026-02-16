defmodule Sykli.ErrorContextTest do
  use ExUnit.Case, async: false

  alias Sykli.ErrorContext

  @test_workdir Path.expand("/tmp/sykli_error_context_test")

  setup do
    File.rm_rf!(@test_workdir)
    File.mkdir_p!(@test_workdir)

    # Initialize git repo with a committed file
    System.cmd("git", ["init", "-b", "main"], cd: @test_workdir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: @test_workdir)
    System.cmd("git", ["config", "user.name", "TestUser"], cd: @test_workdir)

    # Create and commit a file
    src_dir = Path.join(@test_workdir, "src")
    File.mkdir_p!(src_dir)
    File.write!(Path.join(src_dir, "main.go"), "package main\n\nfunc main() {\n}\n")
    System.cmd("git", ["add", "."], cd: @test_workdir)
    System.cmd("git", ["commit", "-m", "initial commit"], cd: @test_workdir)

    on_exit(fn -> File.rm_rf!(@test_workdir) end)

    :ok
  end

  describe "enrich/2" do
    test "returns empty list for nil output" do
      assert ErrorContext.enrich(nil, @test_workdir) == []
    end

    test "returns empty list for empty output" do
      assert ErrorContext.enrich("", @test_workdir) == []
    end

    test "filters out files that don't exist on disk" do
      output = "nonexistent/file.go:10:5: some error"
      assert ErrorContext.enrich(output, @test_workdir) == []
    end

    test "enriches location for existing file with git context" do
      output = "src/main.go:1:1: package main has issues"
      locations = ErrorContext.enrich(output, @test_workdir)

      assert length(locations) == 1
      loc = hd(locations)
      assert loc["file"] == "src/main.go"
      assert loc["line"] == 1

      # Should have git context
      assert is_map(loc["context"])
      assert loc["context"]["last_modified_by"] == "TestUser"
      assert is_binary(loc["context"]["last_commit"])
      assert is_binary(loc["context"]["last_modified_at"])
      assert loc["context"]["recent_commits"] >= 1
    end

    test "preserves message from parsed location" do
      output = "src/main.go:1:1: undefined variable x"
      [loc] = ErrorContext.enrich(output, @test_workdir)
      assert loc["message"] == "undefined variable x"
    end

    test "handles output with no parseable locations" do
      output = "PASS\nok  my-package  0.5s"
      assert ErrorContext.enrich(output, @test_workdir) == []
    end

    test "normalizes absolute paths within workdir to relative" do
      abs_path = Path.join(@test_workdir, "src/main.go")
      output = "#{abs_path}:1:1: absolute path error"
      locations = ErrorContext.enrich(output, @test_workdir)

      assert length(locations) == 1
      # Should be normalized to relative
      assert hd(locations)["file"] == "src/main.go"
    end

    test "filters out absolute paths outside workdir" do
      output = "/some/other/project/file.go:10:5: error"
      assert ErrorContext.enrich(output, @test_workdir) == []
    end
  end

  describe "enrich_locations/2" do
    test "returns empty list for empty locations" do
      assert ErrorContext.enrich_locations([], @test_workdir) == []
    end

    test "enriches pre-parsed locations with git context" do
      locations = [
        %{file: "src/main.go", line: 1, column: 1, message: "some error"}
      ]

      result = ErrorContext.enrich_locations(locations, @test_workdir)
      assert length(result) == 1
      loc = hd(result)
      assert loc["file"] == "src/main.go"
      assert loc["line"] == 1
      assert loc["message"] == "some error"
      assert is_map(loc["context"])
      assert loc["context"]["last_modified_by"] == "TestUser"
    end

    test "filters out non-existent files from pre-parsed locations" do
      locations = [
        %{file: "nonexistent.go", line: 1, column: nil, message: nil},
        %{file: "src/main.go", line: 1, column: nil, message: nil}
      ]

      result = ErrorContext.enrich_locations(locations, @test_workdir)
      assert length(result) == 1
      assert hd(result)["file"] == "src/main.go"
    end

    test "produces same results as enrich/2 for matching output" do
      output = "src/main.go:1:1: undefined variable x"
      from_enrich = ErrorContext.enrich(output, @test_workdir)

      locations = [%{file: "src/main.go", line: 1, column: 1, message: "undefined variable x"}]
      from_locations = ErrorContext.enrich_locations(locations, @test_workdir)

      assert from_enrich == from_locations
    end
  end
end
