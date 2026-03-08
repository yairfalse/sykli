defmodule Sykli.Cache.S3Repository do
  @moduledoc """
  S3-compatible cache repository.

  Stores cache metadata and blobs in an S3 bucket.
  Supports AWS S3, MinIO, and other S3-compatible object stores.

  Configuration via env vars:
  - `SYKLI_CACHE_S3_BUCKET` (required)
  - `SYKLI_CACHE_S3_REGION` (default: us-east-1)
  - `SYKLI_CACHE_S3_ENDPOINT` (optional, for MinIO/custom endpoints)
  - `SYKLI_CACHE_S3_ACCESS_KEY` (required)
  - `SYKLI_CACHE_S3_SECRET_KEY` (required)
  """

  @behaviour Sykli.Cache.Repository

  alias Sykli.Cache.Entry
  alias Sykli.Cache.S3Signer

  @meta_prefix "cache/meta/"
  @blob_prefix "cache/blobs/"

  @impl true
  def init do
    # S3 doesn't need initialization — bucket should already exist
    :ok
  end

  @impl true
  def get(key) do
    path = "#{@meta_prefix}#{key}.json"

    case s3_get(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, Entry.from_map(data)}
          {:error, _} -> {:error, :corrupted}
        end

      {:error, {:http_error, 404}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def put(key, %Entry{} = entry) do
    path = "#{@meta_prefix}#{key}.json"
    body = Jason.encode!(Entry.to_map(entry))
    s3_put(path, body, "application/json")
  end

  @impl true
  def delete(key) do
    s3_delete("#{@meta_prefix}#{key}.json")
    :ok
  end

  @impl true
  def exists?(key) do
    case s3_head("#{@meta_prefix}#{key}.json") do
      :ok -> true
      {:error, _} -> false
    end
  end

  @impl true
  def list_keys do
    case s3_list(@meta_prefix) do
      {:ok, keys} ->
        keys
        |> Enum.map(fn k ->
          k
          |> String.trim_leading(@meta_prefix)
          |> String.trim_trailing(".json")
        end)

      {:error, _} ->
        []
    end
  end

  @impl true
  def store_blob(content) do
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    path = "#{@blob_prefix}#{hash}"

    case s3_put(path, content, "application/octet-stream") do
      :ok -> {:ok, hash}
      error -> error
    end
  end

  @impl true
  def get_blob(hash) do
    s3_get("#{@blob_prefix}#{hash}")
  end

  @impl true
  def blob_exists?(hash) do
    case s3_head("#{@blob_prefix}#{hash}") do
      :ok -> true
      {:error, _} -> false
    end
  end

  @impl true
  def stats do
    %{
      meta_count: length(list_keys()),
      blob_count: 0,
      total_size: 0,
      total_size_human: "unknown (S3)"
    }
  end

  @impl true
  def clean do
    Enum.each(list_keys(), &delete/1)
    :ok
  end

  @impl true
  def clean_older_than(_seconds) do
    # S3 lifecycle policies should handle this
    %{meta_deleted: 0, blobs_deleted: 0}
  end

  # ----- S3 HTTP OPERATIONS -----

  defp s3_get(path) do
    url = build_url(path)
    signed_headers = S3Signer.sign("GET", url, [], "", s3_config())

    headers =
      Enum.map(signed_headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts(), []) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, to_string(body)}
      {:ok, {{_, code, _}, _, _}} -> {:error, {:http_error, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp s3_put(path, body, content_type) do
    url = build_url(path)

    signed_headers =
      S3Signer.sign("PUT", url, [{"content-type", content_type}], body, s3_config())

    headers =
      Enum.map(signed_headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    case :httpc.request(
           :put,
           {String.to_charlist(url), headers, String.to_charlist(content_type), body},
           http_opts(),
           []
         ) do
      {:ok, {{_, code, _}, _, _}} when code in 200..299 -> :ok
      {:ok, {{_, code, _}, _, _}} -> {:error, {:http_error, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp s3_delete(path) do
    url = build_url(path)
    signed_headers = S3Signer.sign("DELETE", url, [], "", s3_config())

    headers =
      Enum.map(signed_headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    case :httpc.request(:delete, {String.to_charlist(url), headers}, http_opts(), []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp s3_head(path) do
    url = build_url(path)
    signed_headers = S3Signer.sign("HEAD", url, [], "", s3_config())

    headers =
      Enum.map(signed_headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    case :httpc.request(:head, {String.to_charlist(url), headers}, http_opts(), []) do
      {:ok, {{_, 200, _}, _, _}} -> :ok
      {:ok, {{_, _, _}, _, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp s3_list(prefix) do
    bucket = System.get_env("SYKLI_CACHE_S3_BUCKET")
    url = "#{endpoint()}/#{bucket}?list-type=2&prefix=#{URI.encode(prefix)}"
    signed_headers = S3Signer.sign("GET", url, [], "", s3_config())

    headers =
      Enum.map(signed_headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts(), []) do
      {:ok, {{_, 200, _}, _, body}} ->
        # Simple XML key extraction
        keys =
          Regex.scan(~r/<Key>([^<]+)<\/Key>/, to_string(body))
          |> Enum.map(fn [_, key] -> key end)

        {:ok, keys}

      {:ok, {{_, code, _}, _, _}} ->
        {:error, {:http_error, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_url(path) do
    bucket = System.get_env("SYKLI_CACHE_S3_BUCKET")
    "#{endpoint()}/#{bucket}/#{path}"
  end

  defp endpoint do
    System.get_env("SYKLI_CACHE_S3_ENDPOINT") || "https://s3.#{region()}.amazonaws.com"
  end

  defp region do
    System.get_env("SYKLI_CACHE_S3_REGION") || "us-east-1"
  end

  defp s3_config do
    %{
      access_key: System.get_env("SYKLI_CACHE_S3_ACCESS_KEY"),
      secret_key: System.get_env("SYKLI_CACHE_S3_SECRET_KEY"),
      region: region()
    }
  end

  defp http_opts do
    [timeout: 30_000, connect_timeout: 5_000] ++ Sykli.HTTP.ssl_opts(endpoint())
  end
end
