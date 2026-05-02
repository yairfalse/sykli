defmodule Sykli.GitHub.Webhook.Receiver do
  @moduledoc "Plug pipeline for GitHub webhook intake."

  import Plug.Conn

  require Logger

  alias Sykli.GitHub.Webhook.{Deliveries, Signature}
  alias Sykli.Occurrence.PubSub, as: OccPubSub

  @role :webhook_receiver
  # GitHub's documented webhook payload ceiling is 25 MB; 10 MB covers
  # large-PR `pull_request` and many-commit `push` payloads with headroom
  # while still bounding worst-case memory per request.
  @max_body_bytes 10_000_000
  @read_timeout_ms 15_000

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", path_info: ["healthz"]} = conn, _opts) do
    if Sykli.Mesh.Roles.held_by_local?(@role) do
      send_text(conn, 200, "ok")
    else
      send_text(conn, 503, "inactive")
    end
  end

  def call(%Plug.Conn{method: "POST", path_info: ["webhook"]} = conn, opts) do
    if Sykli.Mesh.Roles.held_by_local?(@role) do
      handle_webhook(conn, opts)
    else
      send_text(conn, 503, "inactive")
    end
  end

  def call(conn, _opts), do: send_text(conn, 404, "not found")

  defp handle_webhook(conn, opts) do
    with {:ok, body, conn} <- read_full_body(conn, opts),
         :ok <- verify_signature(conn, body, opts),
         :ok <- accept_delivery(conn, opts) do
      case process_accepted(conn, body, opts) do
        {:ok, response_conn} ->
          response_conn

        {:error, error} ->
          # Evict on any post-accept failure, regardless of whether the eventual
          # status is retryable (5xx) or terminal (4xx). For 5xx, eviction is
          # load-bearing: it lets GitHub's automatic retry succeed. For 4xx,
          # eviction is a no-op in practice (GitHub won't retry malformed
          # payloads), so classifying retryable vs terminal here would add code
          # without changing behavior.
          evict_delivery(conn)
          respond_error(conn, error)
      end
    else
      {:error, error} ->
        respond_error(conn, error)
    end
  end

  defp process_accepted(conn, body, opts) do
    with {:ok, payload} <- decode_json(body),
         {:ok, context} <- webhook_context(conn, payload),
         {:ok, token, _expires_at} <-
           app_client(opts).installation_token(context.installation_id, opts),
         {:ok, suite} <-
           checks_client(opts).create_suite(
             %{repo: context.repo, head_sha: context.head_sha},
             token,
             opts
           ),
         {:ok, run} <-
           checks_client(opts).create_run(
             %{repo: context.repo, head_sha: context.head_sha},
             token,
             Keyword.put(opts, :name, "sykli")
           ) do
      broadcast_success(context, suite, run)
      {:ok, send_json(conn, 202, %{ok: true, status: "queued"})}
    end
  end

  defp respond_error(conn, %Sykli.Error{} = error) do
    Logger.warning("[GitHub Webhook] request rejected", code: error.code)

    send_json(conn, status_for(error), %{
      ok: false,
      error: %{code: error.code, message: error.message}
    })
  end

  defp respond_error(conn, reason) do
    Logger.warning("[GitHub Webhook] upstream failure", reason: inspect(reason))

    send_json(conn, 502, %{
      ok: false,
      error: %{
        code: "github.webhook.upstream_failure",
        message: "GitHub webhook handling failed"
      }
    })
  end

  defp read_full_body(conn, opts \\ []) do
    # `max_body_bytes` is overridable via opts so tests can exercise the
    # 413 path without allocating a real 10 MB request body.
    max_bytes = Keyword.get(opts, :max_body_bytes, @max_body_bytes)

    case read_body(conn, length: max_bytes, read_timeout: @read_timeout_ms) do
      {:ok, body, conn} ->
        {:ok, body, conn}

      {:more, _partial, _conn} ->
        {:error,
         webhook_error(
           "github.webhook.body_too_large",
           "GitHub webhook body exceeds size limit"
         )}

      {:error, reason} ->
        {:error,
         webhook_error(
           "github.webhook.body_read_failed",
           "Failed to read webhook body",
           reason
         )}
    end
  end

  defp evict_delivery(conn) do
    case get_req_header(conn, "x-github-delivery") |> List.first() do
      nil -> :ok
      delivery_id -> Deliveries.evict(delivery_id)
    end
  end

  defp verify_signature(conn, body, opts) do
    secret = Keyword.get(opts, :webhook_secret, System.get_env("SYKLI_GITHUB_WEBHOOK_SECRET"))
    signature = get_req_header(conn, "x-hub-signature-256") |> List.first()

    # Order is intentional: `missing_secret` (server misconfig, 503) wins over
    # `missing_signature` (client error, 400). Flipping this would make every
    # request to a misconfigured server look like a client problem.
    cond do
      is_nil(secret) or secret == "" ->
        {:error,
         webhook_error("github.webhook.missing_secret", "GitHub webhook secret is not configured")}

      is_nil(signature) ->
        {:error,
         webhook_error(
           "github.webhook.missing_signature",
           "GitHub webhook signature header is missing"
         )}

      Signature.valid?(secret, body, signature) ->
        :ok

      true ->
        {:error,
         webhook_error("github.webhook.bad_signature", "GitHub webhook signature was invalid")}
    end
  end

  defp accept_delivery(conn, opts) do
    clock =
      Keyword.get(
        opts,
        :clock,
        Application.get_env(:sykli, :github_clock, Sykli.GitHub.Clock.Real)
      )

    delivery_id = get_req_header(conn, "x-github-delivery") |> List.first()

    case Deliveries.accept(delivery_id, clock.now_ms(), opts) do
      :ok ->
        :ok

      {:error, :duplicate_delivery} ->
        {:error,
         webhook_error("github.webhook.replay", "GitHub webhook delivery was already processed")}

      {:error, :missing_delivery_id} ->
        {:error,
         webhook_error("github.webhook.missing_delivery", "GitHub delivery ID is required")}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        {:error,
         webhook_error(
           "github.webhook.invalid_json",
           "GitHub webhook payload was invalid",
           reason
         )}
    end
  end

  defp webhook_context(conn, payload) do
    event = get_req_header(conn, "x-github-event") |> List.first()
    repo = get_in(payload, ["repository", "full_name"])
    installation_id = get_in(payload, ["installation", "id"])
    head_sha = head_sha(event, payload)

    if is_binary(repo) and not is_nil(installation_id) and is_binary(head_sha) do
      {:ok,
       %{
         event: event,
         delivery_id: get_req_header(conn, "x-github-delivery") |> List.first(),
         repo: repo,
         installation_id: installation_id,
         head_sha: head_sha
       }}
    else
      {:error,
       webhook_error(
         "github.webhook.unsupported_payload",
         "GitHub webhook payload is missing repository, installation, or SHA"
       )}
    end
  end

  defp head_sha("pull_request", payload), do: get_in(payload, ["pull_request", "head", "sha"])
  defp head_sha("push", payload), do: payload["after"]
  defp head_sha("check_run", payload), do: get_in(payload, ["check_run", "head_sha"])

  defp head_sha(_event, payload),
    do: payload["after"] || get_in(payload, ["pull_request", "head", "sha"])

  defp broadcast_success(context, suite, run) do
    run_id = "github:#{context.delivery_id}"

    OccPubSub.github_webhook_received(run_id, %{
      event: context.event,
      delivery_id: context.delivery_id,
      repo: context.repo,
      head_sha: context.head_sha
    })

    OccPubSub.github_check_suite_opened(run_id, %{
      repo: context.repo,
      head_sha: context.head_sha,
      check_suite_id: suite["id"],
      check_run_id: run["id"]
    })
  end

  defp app_client(opts),
    do:
      Keyword.get(
        opts,
        :app_client,
        Application.get_env(:sykli, :github_app_impl, Sykli.GitHub.App)
      )

  defp checks_client(opts), do: Keyword.get(opts, :checks_client, Sykli.GitHub.Checks)

  defp status_for(%Sykli.Error{code: "github.webhook.bad_signature"}), do: 401
  defp status_for(%Sykli.Error{code: "github.webhook.missing_signature"}), do: 400
  defp status_for(%Sykli.Error{code: "github.webhook.missing_secret"}), do: 503
  defp status_for(%Sykli.Error{code: "github.webhook.replay"}), do: 409
  defp status_for(%Sykli.Error{code: "github.webhook.missing_delivery"}), do: 400
  defp status_for(%Sykli.Error{code: "github.webhook.invalid_json"}), do: 400
  defp status_for(%Sykli.Error{code: "github.webhook.unsupported_payload"}), do: 400
  defp status_for(%Sykli.Error{code: "github.webhook.body_too_large"}), do: 413
  # `body_read_failed` fires when Plug's read_body returns {:error, _} —
  # typically a timeout or transport IO error on the client connection,
  # not a malformed request. 408 (Request Timeout) is more honest than 400.
  defp status_for(%Sykli.Error{code: "github.webhook.body_read_failed"}), do: 408
  defp status_for(_), do: 502

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_text(conn, status, body), do: send_resp(conn, status, body)

  defp webhook_error(code, message, cause \\ nil) do
    %Sykli.Error{
      code: code,
      type: :runtime,
      message: message,
      step: :setup,
      cause: cause,
      hints: []
    }
  end
end
