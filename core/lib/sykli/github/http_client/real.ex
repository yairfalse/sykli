defmodule Sykli.GitHub.HTTPClient.Real do
  @moduledoc "GitHub HTTP client backed by :httpc."

  @behaviour Sykli.GitHub.HTTPClient

  @impl true
  def request(method, url, headers, body) do
    http_opts = Sykli.HTTP.ssl_opts(url)

    case :httpc.request(
           method,
           {String.to_charlist(url), headers, ~c"application/json", body},
           http_opts,
           []
         ) do
      {:ok, {{_, code, _}, _headers, response}} ->
        {:ok, code, to_string(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
