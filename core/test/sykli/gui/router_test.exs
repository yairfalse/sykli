defmodule Sykli.Gui.RouterTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Sykli.Gui.Router

  @opts Router.init([])

  test "GET /api/state returns the envelope with camelCase state" do
    conn = conn(:get, "/api/state") |> Router.call(@opts)

    assert conn.status == 200
    assert conn.resp_headers |> List.keyfind("content-type", 0) |> elem(1) =~ "application/json"

    assert %{"ok" => true, "version" => "1", "data" => data, "error" => nil} =
             Jason.decode!(conn.resp_body)

    assert data["repo"]["name"] == "false-systems/sykli"
    assert length(data["graph"]["nodes"]) == 4
  end

  test "POST gate approve happy path and validation" do
    conn =
      conn(:post, "/api/gates/approve-release/approve", Jason.encode!(%{actor: "Yair"}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 200
    assert %{"ok" => true, "data" => %{"status" => "approved"}} = Jason.decode!(conn.resp_body)

    missing =
      conn(:post, "/api/gates/approve-release/approve", "{}")
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert missing.status == 422
    assert %{"ok" => false, "error" => %{"message" => msg}} = Jason.decode!(missing.resp_body)
    assert msg =~ "actor"
  end

  test "POST gate reject carries the reason through" do
    conn =
      conn(
        :post,
        "/api/gates/approve-release/reject",
        Jason.encode!(%{actor: "Yair", reason: "evidence incomplete"})
      )
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 200

    assert %{"ok" => true, "data" => %{"status" => "rejected", "reason" => reason}} =
             Jason.decode!(conn.resp_body)

    assert reason == "evidence incomplete"
  end

  test "unknown gate and unknown route return enveloped 404s" do
    gone =
      conn(:post, "/api/gates/nope/approve", Jason.encode!(%{actor: "Yair"}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert gone.status == 404

    lost = conn(:get, "/api/nothing") |> Router.call(@opts)
    assert lost.status == 404
    assert %{"ok" => false} = Jason.decode!(lost.resp_body)
  end

  test "serves embedded SPA assets" do
    for {path, fragment} <- [
          {"/", "<"},
          {"/app.css", ""},
          {"/app.js", ""}
        ] do
      conn = conn(:get, path) |> Router.call(@opts)
      assert conn.status == 200, "expected 200 for #{path}"
      assert conn.resp_body =~ fragment
    end
  end
end
