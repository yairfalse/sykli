defmodule Sykli.MandateEnforcementTest do
  use ExUnit.Case, async: true

  alias Sykli.MandateEnforcement

  describe "parse_porcelain/1" do
    test "plain records yield their path" do
      output = " M lib/a.ex\0?? lib/new.ex\0 D lib/gone.ex\0"

      assert MandateEnforcement.parse_porcelain(output) ==
               MapSet.new(["lib/a.ex", "lib/new.ex", "lib/gone.ex"])
    end

    test "rename records contribute both sides without mangling the origin" do
      output = "R  lib/new_name.ex\0lib/old_name.ex\0 M docs/x.md\0"

      assert MandateEnforcement.parse_porcelain(output) ==
               MapSet.new(["lib/new_name.ex", "lib/old_name.ex", "docs/x.md"])
    end

    test "copy records also consume the origin record" do
      output = "C  lib/copy.ex\0lib/source.ex\0"

      assert MandateEnforcement.parse_porcelain(output) ==
               MapSet.new(["lib/copy.ex", "lib/source.ex"])
    end

    test "empty output yields empty set" do
      assert MandateEnforcement.parse_porcelain("") == MapSet.new()
    end
  end

  describe "scope_match?/2" do
    test "** crosses directory boundaries" do
      assert MandateEnforcement.scope_match?("lib/**", "lib/a.ex")
      assert MandateEnforcement.scope_match?("lib/**", "lib/deep/nested/b.ex")
      refute MandateEnforcement.scope_match?("lib/**", "docs/a.md")
    end

    test "* stays within one segment" do
      assert MandateEnforcement.scope_match?("lib/*.ex", "lib/a.ex")
      refute MandateEnforcement.scope_match?("lib/*.ex", "lib/sub/a.ex")
    end

    test "? matches exactly one character" do
      assert MandateEnforcement.scope_match?("v?.txt", "v1.txt")
      refute MandateEnforcement.scope_match?("v?.txt", "v10.txt")
    end

    test "matching is lexical — deleted files still match their scope" do
      # No filesystem involved: a path that no longer exists matches fine.
      assert MandateEnforcement.scope_match?(["allowed/**"], "allowed/deleted.txt")
    end

    test "regex metacharacters in patterns are literal" do
      assert MandateEnforcement.scope_match?("a+b/c.ex", "a+b/c.ex")
      refute MandateEnforcement.scope_match?("a+b/c.ex", "aab/c.ex")
    end

    test "list scope matches if any pattern matches" do
      assert MandateEnforcement.scope_match?(["docs/**", "lib/**"], "lib/a.ex")
      refute MandateEnforcement.scope_match?(["docs/**", "lib/**"], "test/a.exs")
    end
  end
end
