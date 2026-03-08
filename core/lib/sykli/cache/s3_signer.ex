defmodule Sykli.Cache.S3Signer do
  @moduledoc """
  AWS Signature V4 request signing using pure `:crypto` functions.
  No external dependencies required.
  """

  @doc """
  Sign an HTTP request for AWS S3.

  Returns headers map with Authorization, x-amz-date, and x-amz-content-sha256.
  """
  @spec sign(
          method :: String.t(),
          url :: String.t(),
          headers :: [{String.t(), String.t()}],
          body :: binary(),
          config :: map()
        ) :: [{String.t(), String.t()}]
  def sign(method, url, headers, body, config) do
    access_key = Map.get(config, :access_key)
    secret_key = Map.get(config, :secret_key)
    region = Map.get(config, :region)

    if is_nil(access_key) or is_nil(secret_key) or is_nil(region) do
      raise ArgumentError,
            "S3Signer requires :access_key, :secret_key, and :region; got: #{inspect(Map.keys(config))}"
    end

    service = "s3"
    now = DateTime.utc_now()
    date_stamp = Calendar.strftime(now, "%Y%m%d")
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")

    uri = URI.parse(url)
    canonical_uri = uri.path || "/"
    canonical_querystring = uri.query || ""

    payload_hash = sha256_hex(body || "")

    # Build headers list
    host = uri.host

    all_headers =
      [{"host", host}, {"x-amz-date", amz_date}, {"x-amz-content-sha256", payload_hash}] ++
        headers

    sorted_headers = Enum.sort_by(all_headers, fn {k, _} -> String.downcase(k) end)

    signed_headers =
      sorted_headers |> Enum.map(fn {k, _} -> String.downcase(k) end) |> Enum.join(";")

    canonical_headers =
      sorted_headers
      |> Enum.map(fn {k, v} -> "#{String.downcase(k)}:#{String.trim(v)}\n" end)
      |> Enum.join()

    # Canonical request
    canonical_request =
      Enum.join(
        [
          String.upcase(method),
          canonical_uri,
          canonical_querystring,
          canonical_headers,
          signed_headers,
          payload_hash
        ],
        "\n"
      )

    # String to sign
    credential_scope = "#{date_stamp}/#{region}/#{service}/aws4_request"

    string_to_sign =
      "AWS4-HMAC-SHA256\n#{amz_date}\n#{credential_scope}\n#{sha256_hex(canonical_request)}"

    # Signing key
    signing_key =
      hmac_sha256("AWS4" <> secret_key, date_stamp)
      |> hmac_sha256(region)
      |> hmac_sha256(service)
      |> hmac_sha256("aws4_request")

    signature = hmac_sha256(signing_key, string_to_sign) |> Base.encode16(case: :lower)

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{access_key}/#{credential_scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

    [
      {"Authorization", authorization},
      {"x-amz-date", amz_date},
      {"x-amz-content-sha256", payload_hash}
    ]
  end

  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
