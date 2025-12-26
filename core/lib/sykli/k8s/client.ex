defmodule Sykli.K8s.Client do
  @moduledoc """
  HTTP client for Kubernetes API requests.

  Handles authentication, TLS configuration, JSON encoding/decoding,
  and retry logic for transient failures.

  Uses Erlang's `:httpc` for HTTP requests (no external dependencies).
  """

  alias Sykli.K8s.Error

  @default_retry_delays [100, 200, 400]

  @doc """
  Makes an HTTP request to the Kubernetes API.

  ## Parameters
    * `method` - HTTP method (:get, :post, :put, :patch, :delete)
    * `path` - API path (e.g., "/api/v1/namespaces")
    * `body` - Request body (map for JSON, nil for no body)
    * `config` - Auth config from `Sykli.K8s.Auth`
    * `opts` - Options:
      * `:http_client` - Custom HTTP function for testing
      * `:retry_delays` - List of delays in ms for retries

  ## Returns
    * `{:ok, body}` - Parsed JSON response body
    * `{:error, %Error{}}` - Typed error
  """
  @spec request(atom(), String.t(), map() | nil, map(), keyword()) ::
          {:ok, map() | String.t()} | {:error, Error.t()}
  def request(method, path, body, config, opts \\ []) do
    http_client = Keyword.get(opts, :http_client, &default_http_client/5)
    retry_delays = Keyword.get(opts, :retry_delays, @default_retry_delays)

    url = build_url(path, config)
    headers = build_headers(config)
    encoded_body = encode_body(body)
    ssl_opts = build_ssl_opts(config, opts)

    do_request_with_retry(method, url, headers, encoded_body, ssl_opts, http_client, retry_delays)
  end

  @doc """
  Builds the full URL from path and config.
  """
  @spec build_url(String.t(), map()) :: String.t()
  def build_url(path, %{api_url: api_url}) do
    base = String.trim_trailing(api_url, "/")
    "#{base}#{path}"
  end

  # Private implementation

  defp do_request_with_retry(method, url, headers, body, ssl_opts, http_client, retry_delays) do
    case make_request(method, url, headers, body, ssl_opts, http_client) do
      {:ok, response} ->
        {:ok, response}

      {:error, %Error{} = error} ->
        if Error.retryable?(error) and retry_delays != [] do
          [delay | rest] = retry_delays
          Process.sleep(delay)
          do_request_with_retry(method, url, headers, body, ssl_opts, http_client, rest)
        else
          {:error, error}
        end
    end
  end

  defp make_request(method, url, headers, body, ssl_opts, http_client) do
    case http_client.(method, url, headers, body, ssl: ssl_opts) do
      {:ok, {{_, status_code, _}, _resp_headers, resp_body}} ->
        handle_response(status_code, resp_body)

      {:error, reason} ->
        {:error, Error.new(:connection_error, message: inspect(reason))}
    end
  end

  defp handle_response(status_code, body) when status_code >= 200 and status_code < 300 do
    case decode_body(body) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:ok, to_string(body)}
    end
  end

  defp handle_response(status_code, body) do
    parsed_body =
      case decode_body(body) do
        {:ok, parsed} -> parsed
        {:error, _} -> nil
      end

    {:error, Error.from_status_code(status_code, parsed_body)}
  end

  defp build_headers(%{auth: {:bearer, token}}) do
    [
      {~c"Authorization", ~c"Bearer #{token}"},
      {~c"Content-Type", ~c"application/json"},
      {~c"Accept", ~c"application/json"}
    ]
  end

  defp build_headers(%{auth: {:cert, _}}) do
    [
      {~c"Content-Type", ~c"application/json"},
      {~c"Accept", ~c"application/json"}
    ]
  end

  defp build_ssl_opts(config, opts) do
    base_opts = [
      verify: :verify_peer,
      depth: 10,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    base_opts
    |> add_ca_cert(config)
    |> add_client_cert(config, opts)
  end

  defp add_ca_cert(ssl_opts, %{ca_cert: nil}), do: ssl_opts

  defp add_ca_cert(ssl_opts, %{ca_cert: ca_cert}) when is_binary(ca_cert) do
    case :public_key.pem_decode(ca_cert) do
      [] ->
        ssl_opts

      pem_entries ->
        certs = for {:Certificate, der, :not_encrypted} <- pem_entries, do: der
        Keyword.put(ssl_opts, :cacerts, certs)
    end
  end

  defp add_client_cert(ssl_opts, %{auth: {:cert, {cert_pem, key_pem}}}, _opts) do
    cert_der =
      case :public_key.pem_decode(cert_pem) do
        [{:Certificate, der, :not_encrypted} | _] -> der
        _ -> nil
      end

    key_der =
      case :public_key.pem_decode(key_pem) do
        [{key_type, der, :not_encrypted} | _] when key_type in [:RSAPrivateKey, :PrivateKeyInfo] ->
          {key_type, der}

        _ ->
          nil
      end

    ssl_opts
    |> then(fn opts -> if cert_der, do: Keyword.put(opts, :cert, cert_der), else: opts end)
    |> then(fn opts -> if key_der, do: Keyword.put(opts, :key, key_der), else: opts end)
  end

  defp add_client_cert(ssl_opts, _config, _opts), do: ssl_opts

  defp encode_body(nil), do: ~c""
  defp encode_body(body) when is_map(body), do: Jason.encode!(body)
  defp encode_body(body) when is_binary(body), do: body

  defp decode_body(body) when is_list(body), do: decode_body(to_string(body))
  defp decode_body(""), do: {:ok, %{}}
  defp decode_body(body) when is_binary(body), do: Jason.decode(body)

  defp default_http_client(method, url, headers, body, opts) do
    :inets.start()
    :ssl.start()

    request =
      case method do
        :get -> {to_charlist(url), headers}
        :delete -> {to_charlist(url), headers, ~c"application/json", body}
        _ -> {to_charlist(url), headers, ~c"application/json", body}
      end

    http_opts = [
      ssl: Keyword.get(opts, :ssl, []),
      timeout: 30_000,
      connect_timeout: 10_000
    ]

    :httpc.request(method, request, http_opts, [])
  end
end
