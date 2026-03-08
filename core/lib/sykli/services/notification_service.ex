defmodule Sykli.Services.NotificationService do
  @moduledoc """
  Fire-and-forget webhook notifications for terminal CI events.

  Reads `SYKLI_WEBHOOK_URLS` (comma-separated) and POSTs JSON payloads
  for run pass/fail events. Auto-detects Slack webhook format.

  Timeout: 5s. Never blocks the pipeline.
  """

  require Logger

  @timeout 5_000

  @doc """
  Notify all configured webhooks about a terminal event.
  Fire-and-forget — errors are logged but never propagated.
  """
  @spec notify(map()) :: :ok
  def notify(event) do
    urls = configured_urls()

    if urls != [] do
      # Spawn so we never block the pipeline
      Task.start(fn ->
        Enum.each(urls, fn url ->
          send_notification(url, event)
        end)
      end)
    end

    :ok
  end

  @doc "Returns configured webhook URLs from SYKLI_WEBHOOK_URLS env var."
  @spec configured_urls() :: [String.t()]
  def configured_urls do
    case System.get_env("SYKLI_WEBHOOK_URLS") do
      nil -> []
      "" -> []
      urls -> urls |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end
  end

  defp send_notification(url, event) do
    body = format_payload(url, event)
    url_charlist = String.to_charlist(url)

    headers = [{~c"content-type", ~c"application/json"}]
    http_opts = [timeout: @timeout, connect_timeout: @timeout] ++ Sykli.HTTP.ssl_opts(url)

    case :httpc.request(
           :post,
           {url_charlist, headers, ~c"application/json", body},
           http_opts,
           []
         ) do
      {:ok, {{_, code, _}, _, _}} when code in 200..299 ->
        :ok

      {:ok, {{_, code, _}, _, _}} ->
        Logger.warning("[NotificationService] webhook #{url} returned HTTP #{code}")

      {:error, reason} ->
        Logger.warning("[NotificationService] webhook #{url} failed: #{inspect(reason)}")
    end
  end

  # Auto-detect Slack webhook format
  defp format_payload(url, event) do
    if String.contains?(url, "hooks.slack.com") do
      format_slack(event)
    else
      format_generic(event)
    end
  end

  defp format_slack(event) do
    status = event["type"] || "unknown"
    run_id = event["run_id"] || "?"

    emoji = if String.contains?(status, "passed"), do: ":white_check_mark:", else: ":x:"
    text = "#{emoji} Sykli run `#{run_id}` #{status}"

    Jason.encode!(%{text: text})
  end

  defp format_generic(event) do
    vsn = to_string(Application.spec(:sykli, :vsn) || "unknown")
    Jason.encode!(Map.merge(event, %{"source" => "sykli", "version" => vsn}))
  end
end
