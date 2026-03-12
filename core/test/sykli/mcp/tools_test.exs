defmodule Sykli.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Sykli.MCP.Tools

  describe "list/0" do
    test "returns 7 tool definitions" do
      tools = Tools.list()
      assert length(tools) == 7
    end

    test "each tool has name, description, and inputSchema" do
      Enum.each(Tools.list(), fn tool ->
        assert is_binary(tool["name"]), "Tool missing name"
        assert is_binary(tool["description"]), "Tool #{tool["name"]} missing description"
        assert is_map(tool["inputSchema"]), "Tool #{tool["name"]} missing inputSchema"
        assert tool["inputSchema"]["type"] == "object"
      end)
    end

    test "all tools have path parameter" do
      Enum.each(Tools.list(), fn tool ->
        props = tool["inputSchema"]["properties"] || %{}
        assert Map.has_key?(props, "path"), "Tool #{tool["name"]} missing path param"
      end)
    end
  end

  describe "call/2" do
    test "unknown tool returns error" do
      assert {:error, "Unknown tool: bogus"} = Tools.call("bogus", %{})
    end

    test "explain_pipeline with nonexistent path returns error" do
      path = "/tmp/sykli-mcp-test-#{:rand.uniform(999_999)}"
      assert {:error, message} = Tools.call("explain_pipeline", %{"path" => path})
      assert is_binary(message)
    end

    test "get_history with empty dir returns empty runs" do
      path = System.tmp_dir!() |> Path.join("sykli-mcp-test-#{:rand.uniform(999_999)}")
      File.mkdir_p!(path)

      on_exit(fn -> File.rm_rf!(path) end)

      assert {:ok, result} = Tools.call("get_history", %{"path" => path})
      assert result.runs == []
      assert result.patterns == %{}
    end

    test "get_failure with no data returns error" do
      path = System.tmp_dir!() |> Path.join("sykli-mcp-test-#{:rand.uniform(999_999)}")
      File.mkdir_p!(path)

      on_exit(fn -> File.rm_rf!(path) end)

      assert {:error, message} = Tools.call("get_failure", %{"path" => path})
      assert message =~ "No occurrence data"
    end

    test "tool crash is caught and returns error" do
      # suggest_tests with a nonexistent path should return an error, not crash
      path = "/tmp/sykli-mcp-test-#{:rand.uniform(999_999)}"
      result = Tools.call("suggest_tests", %{"path" => path})
      assert {:error, _message} = result
    end

    test "retry_task with nonexistent path returns error" do
      path = "/tmp/sykli-mcp-test-#{:rand.uniform(999_999)}"
      result = Tools.call("retry_task", %{"path" => path, "tasks" => ["some_task"]})
      assert {:error, message} = result
      assert is_binary(message)
    end

    test "run_fix with nonexistent path returns error" do
      path = "/tmp/sykli-mcp-test-#{:rand.uniform(999_999)}"
      result = Tools.call("run_fix", %{"path" => path})
      assert {:error, message} = result
      assert is_binary(message)
    end
  end

  describe "list/0 tool names" do
    test "includes retry_task and run_fix" do
      names = Tools.list() |> Enum.map(& &1["name"])
      assert "retry_task" in names
      assert "run_fix" in names
    end

    test "all 7 expected tool names are present" do
      names = Tools.list() |> Enum.map(& &1["name"]) |> MapSet.new()

      expected =
        MapSet.new([
          "run_pipeline",
          "explain_pipeline",
          "get_failure",
          "suggest_tests",
          "get_history",
          "retry_task",
          "run_fix"
        ])

      assert MapSet.equal?(names, expected)
    end
  end
end
