defmodule Sykli.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Sykli.MCP.Protocol

  describe "initialize" do
    test "returns server info and capabilities" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"capabilities" => %{}}
      }

      response = Protocol.handle(request)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      result = response["result"]
      assert result["protocolVersion"] == "2024-11-05"
      assert result["serverInfo"]["name"] == "sykli"
      assert is_binary(result["serverInfo"]["version"])
      assert result["capabilities"] == %{"tools" => %{}}
    end
  end

  describe "initialized" do
    test "returns nil (notification)" do
      assert Protocol.handle(%{"method" => "initialized"}) == nil
    end

    test "handles notifications/initialized variant" do
      assert Protocol.handle(%{"method" => "notifications/initialized"}) == nil
    end
  end

  describe "ping" do
    test "returns empty result" do
      request = %{"jsonrpc" => "2.0", "id" => 42, "method" => "ping"}
      response = Protocol.handle(request)

      assert response == %{"jsonrpc" => "2.0", "id" => 42, "result" => %{}}
    end
  end

  describe "tools/list" do
    test "returns tool definitions" do
      request = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}}
      response = Protocol.handle(request)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 2
      tools = response["result"]["tools"]
      assert is_list(tools)
      assert length(tools) == 7

      names = Enum.map(tools, & &1["name"])
      assert "run_pipeline" in names
      assert "explain_pipeline" in names
      assert "get_failure" in names
      assert "suggest_tests" in names
      assert "get_history" in names

      # Each tool has required fields
      Enum.each(tools, fn tool ->
        assert is_binary(tool["name"])
        assert is_binary(tool["description"])
        assert is_map(tool["inputSchema"])
        assert tool["inputSchema"]["type"] == "object"
      end)
    end
  end

  describe "tools/call" do
    test "dispatches to tool and wraps result in content format" do
      # get_history with a nonexistent path should return empty runs
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "get_history",
          "arguments" => %{"path" => "/tmp/nonexistent-sykli-test-#{:rand.uniform(999_999)}"}
        }
      }

      response = Protocol.handle(request)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 3
      result = response["result"]
      content = result["content"]
      assert is_list(content)
      assert length(content) == 1
      assert hd(content)["type"] == "text"
      # Should be valid JSON
      parsed = Jason.decode!(hd(content)["text"])
      assert parsed["runs"] == []
    end

    test "returns isError for unknown tool" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "nonexistent_tool", "arguments" => %{}}
      }

      response = Protocol.handle(request)

      assert response["result"]["isError"] == true
      text = hd(response["result"]["content"])["text"]
      assert text =~ "Unknown tool"
    end
  end

  describe "unknown method" do
    test "returns -32601 error" do
      request = %{"jsonrpc" => "2.0", "id" => 5, "method" => "unknown/method"}
      response = Protocol.handle(request)

      assert response["error"]["code"] == -32601
      assert response["error"]["message"] == "Method not found"
    end
  end

  describe "invalid request" do
    test "returns -32600 for missing method" do
      response = Protocol.handle(%{"jsonrpc" => "2.0", "id" => 6})
      assert response["error"]["code"] == -32600
    end
  end

  describe "parse_error/0" do
    test "returns -32700 with nil id" do
      response = Protocol.parse_error()

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == nil
      assert response["error"]["code"] == -32700
      assert response["error"]["message"] == "Parse error"
    end
  end
end
