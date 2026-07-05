defmodule Sykli.Gui.Router do
  @moduledoc """
  HTTP surface for the Workbench: embedded SPA + JSON API.

  All JSON flows through `Sykli.CLI.JsonResponse` so agents parse the
  same envelope here as everywhere else. Data comes exclusively from the
  configured `Sykli.Gui.Provider` — this layer never knows whether it is
  demo or artifact-backed.
  """

  use Plug.Router

  alias Sykli.CLI.JsonResponse
  alias Sykli.Gui.Assets
  alias Sykli.Gui.Provider

  plug(:match)
  plug(:dispatch)

  get "/" do
    serve_asset(conn, "index.html")
  end

  get("/app.css", do: serve_asset(conn, "app.css"))
  get("/app.js", do: serve_asset(conn, "app.js"))
  get("/fs-mark.png", do: serve_asset(conn, "fs-mark.png"))

  get "/api/state" do
    state =
      Provider.current().state(repo_path: conn.private[:sykli_gui_repo_path] || File.cwd!())

    json_ok(conn, Sykli.Gui.State.to_wire(state))
  end

  get "/api/runs/:id" do
    case Provider.current().run(id) do
      {:ok, run} -> json_ok(conn, run)
      {:error, reason} -> json_error(conn, 404, "run not found: #{inspect(reason)}")
    end
  end

  post "/api/gates/:id/approve" do
    with {:ok, body} <- read_json_body(conn),
         actor when is_binary(actor) and actor != "" <- body["actor"] || :missing_actor,
         {:ok, gate} <- Provider.current().approve_gate(id, actor) do
      json_ok(conn, gate)
    else
      :missing_actor -> json_error(conn, 422, "approve requires an actor")
      {:error, :not_found} -> json_error(conn, 404, "gate not found: #{id}")
      {:error, reason} -> json_error(conn, 500, "gate approve failed: #{inspect(reason)}")
    end
  end

  post "/api/gates/:id/reject" do
    with {:ok, body} <- read_json_body(conn),
         actor when is_binary(actor) and actor != "" <- body["actor"] || :missing_actor,
         {:ok, gate} <-
           Provider.current().reject_gate(id, actor, body["reason"] || "") do
      json_ok(conn, gate)
    else
      :missing_actor -> json_error(conn, 422, "reject requires an actor")
      {:error, :not_found} -> json_error(conn, 404, "gate not found: #{id}")
      {:error, reason} -> json_error(conn, 500, "gate reject failed: #{inspect(reason)}")
    end
  end

  match _ do
    json_error(conn, 404, "not found")
  end

  defp serve_asset(conn, name) do
    case Assets.fetch(name) do
      {:ok, content_type, body} ->
        conn
        |> put_resp_content_type(content_type)
        |> send_resp(200, body)

      :error ->
        send_resp(conn, 404, "asset not built: #{name}")
    end
  end

  defp json_ok(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JsonResponse.ok(data))
  end

  defp json_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JsonResponse.error(message))
  end

  defp read_json_body(conn) do
    case Plug.Conn.read_body(conn, length: 65_536) do
      {:ok, "", _conn} -> {:ok, %{}}
      {:ok, body, _conn} -> Jason.decode(body)
      _ -> {:error, :body_read_failed}
    end
  end
end
