defmodule Sykli.Cache.S3SignerTest do
  use ExUnit.Case, async: true

  alias Sykli.Cache.S3Signer

  @config %{
    access_key: "AKIAIOSFODNN7EXAMPLE",
    secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region: "us-east-1"
  }

  describe "sign/5" do
    test "returns list of header tuples" do
      headers = S3Signer.sign("GET", "https://mybucket.s3.amazonaws.com/mykey", [], "", @config)

      assert is_list(headers)
      assert length(headers) == 3

      header_names = Enum.map(headers, fn {name, _} -> name end)
      assert "Authorization" in header_names
      assert "x-amz-date" in header_names
      assert "x-amz-content-sha256" in header_names
    end

    test "Authorization header has correct format" do
      headers = S3Signer.sign("GET", "https://mybucket.s3.amazonaws.com/mykey", [], "", @config)
      {_, auth} = Enum.find(headers, fn {k, _} -> k == "Authorization" end)

      assert String.starts_with?(auth, "AWS4-HMAC-SHA256 ")
      assert auth =~ "Credential=AKIAIOSFODNN7EXAMPLE/"
      assert auth =~ "/us-east-1/s3/aws4_request"
      assert auth =~ "SignedHeaders="
      assert auth =~ "Signature="
    end

    test "x-amz-date is in ISO 8601 basic format" do
      headers = S3Signer.sign("GET", "https://mybucket.s3.amazonaws.com/mykey", [], "", @config)
      {_, date} = Enum.find(headers, fn {k, _} -> k == "x-amz-date" end)

      # Format: YYYYMMDDTHHMMSSZ
      assert Regex.match?(~r/^\d{8}T\d{6}Z$/, date)
    end

    test "x-amz-content-sha256 is hex-encoded SHA256 of body" do
      body = "hello world"
      expected_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      headers =
        S3Signer.sign("PUT", "https://mybucket.s3.amazonaws.com/mykey", [], body, @config)

      {_, content_sha} = Enum.find(headers, fn {k, _} -> k == "x-amz-content-sha256" end)
      assert content_sha == expected_hash
    end

    test "empty body produces SHA256 of empty string" do
      expected_hash = :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)

      headers = S3Signer.sign("GET", "https://mybucket.s3.amazonaws.com/mykey", [], "", @config)
      {_, content_sha} = Enum.find(headers, fn {k, _} -> k == "x-amz-content-sha256" end)
      assert content_sha == expected_hash
    end

    test "nil body produces SHA256 of empty string" do
      expected_hash = :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)

      headers = S3Signer.sign("GET", "https://mybucket.s3.amazonaws.com/mykey", [], nil, @config)
      {_, content_sha} = Enum.find(headers, fn {k, _} -> k == "x-amz-content-sha256" end)
      assert content_sha == expected_hash
    end

    test "different HTTP methods produce different signatures" do
      get_headers =
        S3Signer.sign("GET", "https://mybucket.s3.amazonaws.com/mykey", [], "", @config)

      put_headers =
        S3Signer.sign("PUT", "https://mybucket.s3.amazonaws.com/mykey", [], "", @config)

      {_, get_auth} = Enum.find(get_headers, fn {k, _} -> k == "Authorization" end)
      {_, put_auth} = Enum.find(put_headers, fn {k, _} -> k == "Authorization" end)

      # Signatures should differ because the canonical request includes the method
      # Note: they could theoretically be the same if signed in the same second,
      # but the method is part of the canonical request so signatures differ
      get_sig = Regex.run(~r/Signature=([a-f0-9]+)/, get_auth) |> List.last()
      put_sig = Regex.run(~r/Signature=([a-f0-9]+)/, put_auth) |> List.last()
      assert get_sig != put_sig
    end

    test "different bodies produce different content hashes" do
      headers_a =
        S3Signer.sign("PUT", "https://mybucket.s3.amazonaws.com/mykey", [], "body-a", @config)

      headers_b =
        S3Signer.sign("PUT", "https://mybucket.s3.amazonaws.com/mykey", [], "body-b", @config)

      {_, sha_a} = Enum.find(headers_a, fn {k, _} -> k == "x-amz-content-sha256" end)
      {_, sha_b} = Enum.find(headers_b, fn {k, _} -> k == "x-amz-content-sha256" end)
      assert sha_a != sha_b
    end

    test "additional headers are included in signed headers" do
      extra = [{"x-amz-meta-custom", "value"}]

      headers =
        S3Signer.sign("PUT", "https://mybucket.s3.amazonaws.com/mykey", extra, "", @config)

      {_, auth} = Enum.find(headers, fn {k, _} -> k == "Authorization" end)
      assert auth =~ "x-amz-meta-custom"
    end

    test "URL with path is handled correctly" do
      headers =
        S3Signer.sign(
          "GET",
          "https://mybucket.s3.amazonaws.com/path/to/object.tar.gz",
          [],
          "",
          @config
        )

      {_, auth} = Enum.find(headers, fn {k, _} -> k == "Authorization" end)
      assert auth =~ "AWS4-HMAC-SHA256"
    end

    test "URL with query string is handled" do
      headers =
        S3Signer.sign(
          "GET",
          "https://mybucket.s3.amazonaws.com/key?prefix=test&max-keys=10",
          [],
          "",
          @config
        )

      {_, auth} = Enum.find(headers, fn {k, _} -> k == "Authorization" end)
      assert auth =~ "AWS4-HMAC-SHA256"
    end

    test "raises when config missing access_key" do
      bad_config = %{secret_key: "secret", region: "us-east-1"}

      assert_raise ArgumentError, fn ->
        S3Signer.sign("GET", "https://example.com/key", [], "", bad_config)
      end
    end

    test "raises when config missing secret_key" do
      bad_config = %{access_key: "key", region: "us-east-1"}

      assert_raise ArgumentError, fn ->
        S3Signer.sign("GET", "https://example.com/key", [], "", bad_config)
      end
    end

    test "raises when config missing region" do
      bad_config = %{access_key: "key", secret_key: "secret"}

      assert_raise ArgumentError, fn ->
        S3Signer.sign("GET", "https://example.com/key", [], "", bad_config)
      end
    end

    test "credential scope includes correct region" do
      eu_config = %{@config | region: "eu-west-1"}

      headers =
        S3Signer.sign("GET", "https://mybucket.s3.eu-west-1.amazonaws.com/key", [], "", eu_config)

      {_, auth} = Enum.find(headers, fn {k, _} -> k == "Authorization" end)
      assert auth =~ "/eu-west-1/s3/aws4_request"
    end
  end
end
