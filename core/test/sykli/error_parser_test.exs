defmodule Sykli.ErrorParserTest do
  use ExUnit.Case, async: true

  alias Sykli.ErrorParser

  describe "parse/1 — Go errors" do
    test "parses file:line:col: message" do
      output = "main.go:15:3: undefined: Foo"

      assert [%{file: "main.go", line: 15, column: 3, message: "undefined: Foo"}] =
               ErrorParser.parse(output)
    end

    test "parses multiple Go errors" do
      output = """
      main.go:15:3: undefined: Foo
      pkg/util.go:42:10: cannot use x (type int) as string
      """

      locations = ErrorParser.parse(output)
      assert length(locations) == 2
      assert Enum.at(locations, 0).file == "main.go"
      assert Enum.at(locations, 1).file == "pkg/util.go"
    end
  end

  describe "parse/1 — Rust errors" do
    test "parses --> file:line:col" do
      output = """
      error[E0425]: cannot find value `x`
        --> src/main.rs:10:5
         |
      10 |     x + 1
         |     ^ not found
      """

      assert [%{file: "src/main.rs", line: 10, column: 5}] = ErrorParser.parse(output)
    end

    test "parses multiple Rust locations" do
      output = """
      error[E0425]: cannot find value `x`
        --> src/main.rs:10:5
      error[E0308]: mismatched types
        --> src/lib.rs:25:12
      """

      locations = ErrorParser.parse(output)
      assert length(locations) == 2
      assert Enum.at(locations, 0).file == "src/main.rs"
      assert Enum.at(locations, 1).file == "src/lib.rs"
    end
  end

  describe "parse/1 — TypeScript errors" do
    test "parses file(line,col): message" do
      output = "src/app.ts(10,5): error TS2304: Cannot find name 'foo'"

      assert [%{file: "src/app.ts", line: 10, column: 5, message: msg}] =
               ErrorParser.parse(output)

      assert String.contains?(msg, "TS2304")
    end
  end

  describe "parse/1 — Python errors" do
    test "parses File \"path\", line N with message from next line" do
      output = """
      Traceback (most recent call last):
        File "test_auth.py", line 15, in test_login
          assert response.status == 200
      AssertionError
      """

      assert [%{file: "test_auth.py", line: 15, column: nil, message: msg}] =
               ErrorParser.parse(output)

      assert msg == "assert response.status == 200"
    end

    test "parses nested Python traceback with messages" do
      output = """
        File "src/auth/login.py", line 42, in authenticate
          token = generate_token()
        File "src/auth/token.py", line 8, in generate_token
          raise ValueError("invalid key")
      """

      locations = ErrorParser.parse(output)
      assert length(locations) == 2
      assert Enum.at(locations, 0).file == "src/auth/login.py"
      assert Enum.at(locations, 0).message == "token = generate_token()"
      assert Enum.at(locations, 1).file == "src/auth/token.py"
      assert Enum.at(locations, 1).message == "raise ValueError(\"invalid key\")"
    end

    test "Python message is nil when next line is another File reference" do
      output = """
        File "a.py", line 1, in foo
        File "b.py", line 2, in bar
          actual_error()
      """

      locations = ErrorParser.parse(output)
      assert length(locations) == 2
      assert Enum.at(locations, 0).message == nil
      assert Enum.at(locations, 1).message == "actual_error()"
    end

    test "Python message is nil at end of output" do
      output = "  File \"last.py\", line 99, in main"
      [loc] = ErrorParser.parse(output)
      assert loc.file == "last.py"
      assert loc.message == nil
    end
  end

  describe "parse/1 — Elixir errors" do
    test "parses (file.ex:line) format" do
      output = """
      ** (CompileError) (lib/auth.ex:42) undefined function foo/0
      """

      assert [%{file: "lib/auth.ex", line: 42}] = ErrorParser.parse(output)
    end

    test "parses colon-style file.ex:line: message" do
      output = "lib/auth.ex:42: warning: variable x is unused"

      assert [%{file: "lib/auth.ex", line: 42, message: msg}] = ErrorParser.parse(output)
      assert String.contains?(msg, "variable x is unused")
    end

    test "parses .erl Erlang file in parens" do
      output = """
      ** (CompileError) (src/gen_server_impl.erl:15) undefined callback
      """

      assert [%{file: "src/gen_server_impl.erl", line: 15}] = ErrorParser.parse(output)
    end

    test "parses .hrl header file in parens" do
      output = """
      ** (CompileError) (include/records.hrl:8) bad record definition
      """

      assert [%{file: "include/records.hrl", line: 8}] = ErrorParser.parse(output)
    end
  end

  describe "parse/1 — generic patterns" do
    test "parses standard file:line:col: message" do
      output = "src/main.c:100:5: error: expected ';'"

      assert [%{file: "src/main.c", line: 100, column: 5}] = ErrorParser.parse(output)
    end

    test "parses file:line: message (no column)" do
      output = "build.mk:42: recipe for target 'build' failed"

      assert [%{file: "build.mk", line: 42, message: msg}] = ErrorParser.parse(output)
      assert String.contains?(msg, "recipe for target")
    end
  end

  describe "parse/1 — dedup and limits" do
    test "deduplicates by file:line" do
      output = """
      src/main.go:15:3: error one
      src/main.go:15:5: error two
      """

      # Same file:line, different columns — deduped
      assert length(ErrorParser.parse(output)) == 1
    end

    test "caps at 5 locations" do
      lines =
        for i <- 1..10, do: "src/file#{i}.go:#{i}:1: error #{i}"

      output = Enum.join(lines, "\n")
      assert length(ErrorParser.parse(output)) == 5
    end
  end

  describe "parse/1 — edge cases" do
    test "returns empty list for nil" do
      assert ErrorParser.parse(nil) == []
    end

    test "returns empty list for empty string" do
      assert ErrorParser.parse("") == []
    end

    test "returns empty list for output with no file references" do
      output = """
      FAIL
      Tests:  2 failed, 10 passed, 12 total
      Time:   3.456s
      """

      assert ErrorParser.parse(output) == []
    end

    test "ignores URL-like patterns" do
      output = "https://example.com:443/path — connection refused"
      assert ErrorParser.parse(output) == []
    end

    test "ignores IP address patterns" do
      output = "192.168.1.1:8080:0: connection refused"
      assert ErrorParser.parse(output) == []
    end

    test "ignores bare version numbers" do
      output = "v1.2:3:4: something"
      assert ErrorParser.parse(output) == []
    end
  end
end
