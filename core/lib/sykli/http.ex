defmodule Sykli.HTTP do
  @moduledoc """
  Shared HTTP helpers for :httpc callers.
  Provides TLS verification options for HTTPS endpoints.
  """

  @doc """
  Returns SSL options for :httpc that verify server certificates and hostnames.
  """
  @spec ssl_opts(String.t()) :: keyword()
  def ssl_opts(url) do
    uri = URI.parse(url)

    case uri do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        [
          ssl: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: String.to_charlist(host),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ],
            depth: 3
          ]
        ]

      _ ->
        []
    end
  end
end
