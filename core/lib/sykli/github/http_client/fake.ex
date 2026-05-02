defmodule Sykli.GitHub.HTTPClient.Fake do
  @moduledoc "Fake GitHub HTTP client for tests."

  @behaviour Sykli.GitHub.HTTPClient

  @impl true
  def request(method, url, headers, body) do
    case Application.get_env(:sykli, :github_http_client_fake_response, {:ok, 200, "{}"}) do
      {:ok, _code, _response} = ok ->
        notify({:github_http_request, method, url, headers, body})
        ok

      {:error, _reason} = error ->
        notify({:github_http_request, method, url, headers, body})
        error
    end
  end

  defp notify(message) do
    case Application.get_env(:sykli, :github_http_client_fake_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end
