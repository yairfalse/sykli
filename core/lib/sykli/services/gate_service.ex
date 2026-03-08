defmodule Sykli.Services.GateService do
  @moduledoc """
  Handles gate approval logic for different strategies.
  """

  alias Sykli.Graph.Task.Gate

  @type approval_result :: {:approved, String.t()} | {:denied, String.t()} | {:timed_out}

  @doc "Wait for approval based on gate strategy."
  @spec wait(Gate.t()) :: approval_result()
  def wait(%Gate{strategy: :prompt} = gate) do
    wait_prompt(gate)
  end

  def wait(%Gate{strategy: :env} = gate) do
    wait_env(gate)
  end

  def wait(%Gate{strategy: :file} = gate) do
    wait_file(gate)
  end

  def wait(%Gate{strategy: :webhook} = gate) do
    wait_webhook(gate)
  end

  defp wait_prompt(%Gate{message: message, timeout: timeout}) do
    prompt = message || "Approve? [y/n]"

    # Check if we have a TTY (io:columns succeeds when connected to a terminal)
    if match?({:ok, _}, :io.columns()) do
      IO.puts("")
      IO.puts("#{IO.ANSI.yellow()}⏸ GATE: #{prompt}#{IO.ANSI.reset()}")

      task =
        Task.async(fn ->
          response = IO.gets("  Enter [y]es / [n]o: ")

          case String.trim(String.downcase(response || "")) do
            r when r in ["y", "yes"] -> {:approved, "interactive"}
            _ -> {:denied, "interactive"}
          end
        end)

      case Task.yield(task, timeout * 1000) || Task.shutdown(task) do
        {:ok, result} -> result
        nil -> {:timed_out}
      end
    else
      {:denied,
       "no TTY available for prompt strategy — use env or file strategy in non-interactive environments"}
    end
  end

  defp wait_env(%Gate{env_var: env_var, timeout: timeout})
       when is_binary(env_var) and env_var != "" do
    poll_interval = 1_000
    deadline = System.monotonic_time(:millisecond) + timeout * 1000
    do_wait_env(env_var, poll_interval, deadline)
  end

  defp wait_env(_), do: {:denied, "env strategy requires env_var to be set"}

  defp do_wait_env(env_var, poll_interval, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:timed_out}
    else
      case System.get_env(env_var) do
        nil ->
          Process.sleep(poll_interval)
          do_wait_env(env_var, poll_interval, deadline)

        "approved" ->
          {:approved, "env:#{env_var}"}

        "denied" ->
          {:denied, "env:#{env_var}"}

        val when val in ["1", "true", "yes"] ->
          {:approved, "env:#{env_var}"}

        _ ->
          {:denied, "env:#{env_var}"}
      end
    end
  end

  defp wait_file(%Gate{file_path: file_path, timeout: timeout})
       when is_binary(file_path) and file_path != "" do
    poll_interval = 1_000
    deadline = System.monotonic_time(:millisecond) + timeout * 1000
    do_wait_file(file_path, poll_interval, deadline)
  end

  defp wait_file(_), do: {:denied, "file strategy requires file_path to be set"}

  defp do_wait_file(file_path, poll_interval, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:timed_out}
    else
      if File.exists?(file_path) do
        case File.read(file_path) do
          {:ok, content} ->
            case String.trim(content) do
              "approved" -> {:approved, "file:#{file_path}"}
              "denied" -> {:denied, "file:#{file_path}"}
              "" -> {:approved, "file:#{file_path}"}
              _ -> {:approved, "file:#{file_path}"}
            end

          {:error, _} ->
            {:approved, "file:#{file_path}"}
        end
      else
        Process.sleep(poll_interval)
        do_wait_file(file_path, poll_interval, deadline)
      end
    end
  end

  defp wait_webhook(%Gate{webhook_url: url, message: message, timeout: timeout})
       when is_binary(url) and url != "" do
    body =
      Jason.encode!(%{
        type: "gate_approval_request",
        message: message || "Gate approval requested",
        timestamp: DateTime.to_iso8601(DateTime.utc_now())
      })

    url_charlist = String.to_charlist(url)
    timeout_ms = timeout * 1000

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"application/json"}
    ]

    http_opts = [timeout: timeout_ms, connect_timeout: 5_000] ++ Sykli.HTTP.ssl_opts(url)

    case :httpc.request(
           :post,
           {url_charlist, headers, ~c"application/json", body},
           http_opts,
           []
         ) do
      {:ok, {{_, status, _}, _headers, resp_body}} when status in 200..299 ->
        parse_webhook_response(to_string(resp_body))

      {:ok, {{_, status, _}, _headers, _resp_body}} ->
        {:denied, "webhook returned HTTP #{status}"}

      {:error, :timeout} ->
        {:timed_out}

      {:error, reason} ->
        {:denied, "webhook request failed: #{inspect(reason)}"}
    end
  end

  defp wait_webhook(_), do: {:denied, "webhook strategy requires webhook_url to be set"}

  defp parse_webhook_response(body) do
    case Jason.decode(body) do
      {:ok, %{"approved" => true} = resp} ->
        approver = resp["approver"] || "webhook"
        {:approved, approver}

      {:ok, %{"approved" => false} = resp} ->
        reason = resp["reason"] || "denied by webhook"
        {:denied, reason}

      {:ok, _} ->
        {:denied, "invalid webhook response format"}

      {:error, _} ->
        {:denied, "webhook returned invalid JSON"}
    end
  end
end
