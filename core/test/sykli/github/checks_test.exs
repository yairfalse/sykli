defmodule Sykli.GitHub.ChecksTest do
  use ExUnit.Case, async: false

  alias Sykli.GitHub.Checks

  setup do
    Application.delete_env(:sykli, :github_http_requests)
    :ok
  end

  test "create_suite posts queued suite request through the HTTP behaviour" do
    assert {:ok, %{"id" => 101}} =
             Checks.create_suite(%{repo: "false-systems/sykli", head_sha: "abc123"}, "token",
               http_client: __MODULE__.HTTP,
               api_url: "https://api.github.test"
             )

    [{:post, url, body}] = Application.get_env(:sykli, :github_http_requests)
    assert url == "https://api.github.test/repos/false-systems/sykli/check-suites"
    assert Jason.decode!(body) == %{"head_sha" => "abc123"}
  end

  test "create_run creates check run with requested status" do
    assert {:ok, %{"id" => 202}} =
             Checks.create_run(%{repo: "false-systems/sykli", head_sha: "abc123"}, "token",
               http_client: __MODULE__.HTTP,
               api_url: "https://api.github.test",
               name: "sykli",
               status: "in_progress"
             )

    [{:post, url, body}] = Application.get_env(:sykli, :github_http_requests)
    assert url == "https://api.github.test/repos/false-systems/sykli/check-runs"

    assert Jason.decode!(body) == %{
             "head_sha" => "abc123",
             "name" => "sykli",
             "status" => "in_progress"
           }
  end

  @tag :integration
  test "create_suite works against a localhost stub server" do
    port = free_port()
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.Stub, port: port, startup_log: false)

    try do
      assert {:ok, %{"id" => 303}} =
               Checks.create_suite(%{repo: "false-systems/sykli", head_sha: "abc123"}, "token",
                 api_url: "http://127.0.0.1:#{port}"
               )
    after
      Process.exit(pid, :normal)
    end
  end

  defmodule HTTP do
    def request(method, url, _headers, body) do
      requests = Application.get_env(:sykli, :github_http_requests, [])
      Application.put_env(:sykli, :github_http_requests, [{method, url, body} | requests])

      id = if String.ends_with?(url, "/check-runs"), do: 202, else: 101
      {:ok, 201, Jason.encode!(%{id: id})}
    end
  end

  defmodule Stub do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"head_sha" => "abc123"}

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, Jason.encode!(%{id: 303}))
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
