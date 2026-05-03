defmodule Sykli.GitHub.Webhook.ReceiverTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  import ExUnit.CaptureLog

  alias Sykli.GitHub.Webhook.{Deliveries, Receiver, Signature}
  alias Sykli.Mesh.Roles
  alias Sykli.Occurrence.PubSub

  @secret "webhook-secret"
  @body Jason.encode!(%{
          installation: %{id: 123},
          repository: %{full_name: "false-systems/sykli"},
          pull_request: %{head: %{sha: "abc123"}}
        })

  setup do
    Deliveries.clear()
    Roles.clear()
    PubSub.subscribe()

    on_exit(fn ->
      PubSub.unsubscribe()
      Deliveries.clear()
      Roles.clear()
    end)

    :ok
  end

  test "healthz returns 200 only when local node holds the receiver role" do
    assert %{status: 503, resp_body: "inactive"} =
             conn(:get, "/healthz")
             |> Receiver.call([])

    assert :ok = Roles.acquire(:webhook_receiver)

    assert %{status: 200, resp_body: "ok"} =
             conn(:get, "/healthz")
             |> Receiver.call([])
  end

  test "POST /webhook returns 503 when local node does not hold the receiver role" do
    conn =
      :post
      |> conn("/webhook", @body)
      |> put_req_header("x-hub-signature-256", Signature.sign(@secret, @body))
      |> put_req_header("x-github-delivery", "delivery-not-receiver")
      |> put_req_header("x-github-event", "pull_request")
      |> Receiver.call(
        webhook_secret: @secret,
        clock: Sykli.GitHub.Clock.Fake,
        dispatcher: __MODULE__.Dispatcher,
        test_pid: self()
      )

    assert conn.status == 503
    assert conn.resp_body == "inactive"
  end

  test "signed webhook opens queued GitHub checks and broadcasts occurrences" do
    :ok = Roles.acquire(:webhook_receiver)

    conn =
      :post
      |> conn("/webhook", @body)
      |> put_req_header("x-hub-signature-256", Signature.sign(@secret, @body))
      |> put_req_header("x-github-delivery", "delivery-1")
      |> put_req_header("x-github-event", "pull_request")
      |> Receiver.call(
        webhook_secret: @secret,
        clock: Sykli.GitHub.Clock.Fake,
        dispatcher: __MODULE__.Dispatcher,
        test_pid: self()
      )

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"ok" => true, "status" => "queued"}

    assert_receive %Sykli.Occurrence{
      type: "ci.github.webhook.received",
      data: %{repo: "false-systems/sykli"}
    }

    assert_receive {:receiver_dispatch, %{repo: "false-systems/sykli", head_sha: "abc123"}}
  end

  test "wrong signature is rejected without logging the raw body" do
    :ok = Roles.acquire(:webhook_receiver)

    log =
      capture_log(fn ->
        conn =
          :post
          |> conn("/webhook", @body)
          |> put_req_header("x-hub-signature-256", "sha256=bad")
          |> put_req_header("x-github-delivery", "delivery-1")
          |> put_req_header("x-github-event", "pull_request")
          |> Receiver.call(webhook_secret: @secret)

        assert conn.status == 401
        assert Jason.decode!(conn.resp_body)["error"]["code"] == "github.webhook.bad_signature"
      end)

    assert log =~ "request rejected"
    refute log =~ @body
    refute log =~ "abc123"
  end

  test "missing signature header returns 400 with a distinct error code" do
    :ok = Roles.acquire(:webhook_receiver)

    conn =
      :post
      |> conn("/webhook", @body)
      |> put_req_header("x-github-delivery", "delivery-no-sig")
      |> put_req_header("x-github-event", "pull_request")
      |> Receiver.call(webhook_secret: @secret)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "github.webhook.missing_signature"
  end

  test "request body over the configured size limit returns 413" do
    :ok = Roles.acquire(:webhook_receiver)

    oversized_body = String.duplicate("x", 10_000)

    conn =
      :post
      |> conn("/webhook", oversized_body)
      |> put_req_header("x-hub-signature-256", Signature.sign(@secret, oversized_body))
      |> put_req_header("x-github-delivery", "delivery-too-big")
      |> put_req_header("x-github-event", "pull_request")
      |> Receiver.call(webhook_secret: @secret, max_body_bytes: 10)

    assert conn.status == 413
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "github.webhook.body_too_large"
  end

  test "duplicate delivery is rejected" do
    :ok = Roles.acquire(:webhook_receiver)

    opts = [
      webhook_secret: @secret,
      clock: Sykli.GitHub.Clock.Fake,
      dispatcher: __MODULE__.Dispatcher,
      test_pid: self()
    ]

    first =
      :post
      |> conn("/webhook", @body)
      |> put_req_header("x-hub-signature-256", Signature.sign(@secret, @body))
      |> put_req_header("x-github-delivery", "delivery-1")
      |> put_req_header("x-github-event", "pull_request")
      |> Receiver.call(opts)

    second =
      :post
      |> conn("/webhook", @body)
      |> put_req_header("x-hub-signature-256", Signature.sign(@secret, @body))
      |> put_req_header("x-github-delivery", "delivery-1")
      |> put_req_header("x-github-event", "pull_request")
      |> Receiver.call(opts)

    assert first.status == 202
    assert second.status == 409
  end

  test "post-accept dispatch failure evicts the delivery so a retry can succeed" do
    :ok = Roles.acquire(:webhook_receiver)

    opts_failing = [
      webhook_secret: @secret,
      clock: Sykli.GitHub.Clock.Fake,
      dispatcher: __MODULE__.Dispatcher,
      test_pid: self(),
      dispatch_result:
        {:error,
         %Sykli.Error{
           code: "github.dispatch.failed",
           type: :runtime,
           message: "dispatch failed",
           step: :run,
           hints: []
         }}
    ]

    opts_ok = Keyword.put(opts_failing, :dispatch_result, :ok)

    failing =
      :post
      |> conn("/webhook", @body)
      |> put_req_header("x-hub-signature-256", Signature.sign(@secret, @body))
      |> put_req_header("x-github-delivery", "delivery-retry-me")
      |> put_req_header("x-github-event", "pull_request")
      |> Receiver.call(opts_failing)

    assert failing.status == 202
    assert_receive {:receiver_dispatch, %{delivery_id: "delivery-retry-me"}}

    assert_receive {:receiver_dispatch_completed, "delivery-retry-me"}

    retry =
      :post
      |> conn("/webhook", @body)
      |> put_req_header("x-hub-signature-256", Signature.sign(@secret, @body))
      |> put_req_header("x-github-delivery", "delivery-retry-me")
      |> put_req_header("x-github-event", "pull_request")
      |> Receiver.call(opts_ok)

    assert retry.status == 202
  end

  @tag :integration
  test "Phase 1 loop accepts signed webhook and rejects unsigned webhook" do
    :ok = Roles.acquire(:webhook_receiver)

    signed =
      :post
      |> conn("/webhook", @body)
      |> put_req_header("x-hub-signature-256", Signature.sign(@secret, @body))
      |> put_req_header("x-github-delivery", "delivery-integration-1")
      |> put_req_header("x-github-event", "pull_request")
      |> Receiver.call(
        webhook_secret: @secret,
        clock: Sykli.GitHub.Clock.Fake,
        dispatcher: __MODULE__.Dispatcher,
        test_pid: self()
      )

    unsigned =
      :post
      |> conn("/webhook", @body)
      |> put_req_header("x-github-delivery", "delivery-integration-2")
      |> put_req_header("x-github-event", "pull_request")
      |> Receiver.call(webhook_secret: @secret)

    assert signed.status == 202
    assert unsigned.status == 400

    assert Jason.decode!(unsigned.resp_body)["error"]["code"] ==
             "github.webhook.missing_signature"
  end

  defmodule Dispatcher do
    def dispatch(context, opts) do
      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:receiver_dispatch, context})
      end

      result =
        case Keyword.get(opts, :dispatch_result, :ok) do
          {:error, _error} = error ->
            Sykli.GitHub.Webhook.Deliveries.evict(context.delivery_id)
            error

          :ok ->
            :ok
        end

      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:receiver_dispatch_completed, context.delivery_id})
      end

      result
    end
  end
end
