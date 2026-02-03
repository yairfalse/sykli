defmodule Sykli.Graph.Task.AiHooksTest do
  use ExUnit.Case, async: true

  alias Sykli.Graph.Task.AiHooks

  describe "from_map/1" do
    test "creates empty hooks from nil" do
      assert %AiHooks{on_fail: nil, select: nil} = AiHooks.from_map(nil)
    end

    test "parses full hooks map" do
      map = %{
        "on_fail" => "analyze",
        "select" => "smart"
      }

      hooks = AiHooks.from_map(map)

      assert hooks.on_fail == :analyze
      assert hooks.select == :smart
    end

    test "parses on_fail options" do
      assert %AiHooks{on_fail: :analyze} = AiHooks.from_map(%{"on_fail" => "analyze"})
      assert %AiHooks{on_fail: :retry} = AiHooks.from_map(%{"on_fail" => "retry"})
      assert %AiHooks{on_fail: :skip} = AiHooks.from_map(%{"on_fail" => "skip"})
      assert %AiHooks{on_fail: nil} = AiHooks.from_map(%{"on_fail" => "invalid"})
    end

    test "parses select options" do
      assert %AiHooks{select: :smart} = AiHooks.from_map(%{"select" => "smart"})
      assert %AiHooks{select: :always} = AiHooks.from_map(%{"select" => "always"})
      assert %AiHooks{select: :manual} = AiHooks.from_map(%{"select" => "manual"})
      assert %AiHooks{select: nil} = AiHooks.from_map(%{"select" => "invalid"})
    end
  end

  describe "to_map/1" do
    test "serializes hooks to map" do
      hooks = %AiHooks{on_fail: :analyze, select: :smart}
      map = AiHooks.to_map(hooks)

      assert map["on_fail"] == "analyze"
      assert map["select"] == "smart"
    end

    test "excludes nil values" do
      hooks = %AiHooks{on_fail: nil, select: nil}
      map = AiHooks.to_map(hooks)

      assert map == %{}
    end
  end

  describe "analyze_on_fail?/1" do
    test "returns true when on_fail is analyze" do
      assert AiHooks.analyze_on_fail?(%AiHooks{on_fail: :analyze})
    end

    test "returns false otherwise" do
      refute AiHooks.analyze_on_fail?(%AiHooks{on_fail: :retry})
      refute AiHooks.analyze_on_fail?(%AiHooks{on_fail: nil})
    end
  end

  describe "smart_select?/1" do
    test "returns true when select is smart" do
      assert AiHooks.smart_select?(%AiHooks{select: :smart})
    end

    test "returns false otherwise" do
      refute AiHooks.smart_select?(%AiHooks{select: :always})
      refute AiHooks.smart_select?(%AiHooks{select: nil})
    end
  end
end
