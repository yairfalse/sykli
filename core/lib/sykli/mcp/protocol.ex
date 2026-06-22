defmodule Sykli.MCP.Protocol do
  @moduledoc """
  JSON-RPC 2.0 dispatch for the MCP server.

  Pure functions: `handle(request_map) -> response_map | nil`.

  Handles the MCP lifecycle methods (initialize, initialized, ping)
  and dispatches tool calls to `Sykli.MCP.Tools`.
  """

  alias Sykli.CLI.JsonResponse
  alias Sykli.MCP.Tools

  @server_name "sykli"
  @server_version Mix.Project.config()[:version]
  @protocol_version "2024-11-05"

  @doc """
  Dispatches a decoded JSON-RPC request map to the appropriate handler.

  Returns a response map, or `nil` for notifications (no `id` field).
  """
  @spec handle(map()) :: map() | nil
  def handle(%{"method" => "initialize", "id" => id}) do
    ok_response(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{
        "name" => @server_name,
        "version" => @server_version
      }
    })
  end

  # initialized is a notification — no response
  def handle(%{"method" => "initialized"}) do
    nil
  end

  def handle(%{"method" => "notifications/initialized"}) do
    nil
  end

  def handle(%{"method" => "ping", "id" => id}) do
    ok_response(id, %{})
  end

  def handle(%{"method" => "tools/list", "id" => id}) do
    ok_response(id, %{"tools" => Tools.list()})
  end

  def handle(%{"method" => "tools/call", "id" => id, "params" => params}) do
    name = params["name"]
    arguments = params["arguments"] || %{}

    case Tools.call(name, arguments) do
      {:ok, result} ->
        ok_response(id, %{
          "content" => [%{"type" => "text", "text" => JsonResponse.ok(result)}]
        })

      {:error, %Sykli.Error{} = error} ->
        ok_response(id, %{
          "content" => [%{"type" => "text", "text" => JsonResponse.error(error)}],
          "isError" => true
        })
    end
  end

  def handle(%{"method" => _method, "id" => id}) do
    error_response(id, -32601, "Method not found")
  end

  # Notifications without id — ignore unknown ones
  def handle(%{"method" => _method}) do
    nil
  end

  # Malformed request (no method)
  def handle(_) do
    error_response(nil, -32600, "Invalid request")
  end

  @doc """
  Builds a JSON-RPC error response for parse errors.
  """
  @spec parse_error() :: map()
  def parse_error do
    error_response(nil, -32700, "Parse error")
  end

  # --- Response builders ---

  defp ok_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }
  end
end
