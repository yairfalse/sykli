defmodule Sykli.Cache.FileRepository do
  @moduledoc """
  File-based cache repository implementation.

  Stores cache metadata and output blobs on the local filesystem:

      ~/.sykli/cache/
      ├── meta/
      │   └── <key>.json          # task metadata
      └── blobs/
          └── <sha256>            # content-addressed files
  """

  @behaviour Sykli.Cache.Repository

  alias Sykli.Cache.Entry

  # Runtime path expansion (not compile-time) for Burrito compatibility
  defp cache_dir, do: Path.expand("~/.sykli/cache")
  defp meta_dir, do: Path.join(cache_dir(), "meta")
  defp blobs_dir, do: Path.join(cache_dir(), "blobs")

  # ─────────────────────────────────────────────────────────────────────────────
  # INITIALIZATION
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def init do
    with :ok <- File.mkdir_p(meta_dir()),
         :ok <- File.mkdir_p(blobs_dir()) do
      :ok
    else
      {:error, reason} -> {:error, {:init_failed, reason}}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ENTRY OPERATIONS
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def get(key) do
    path = meta_path(key)

    case read_meta(path) do
      {:ok, meta} ->
        Entry.from_map(meta)

      {:error, :corrupted} ->
        cleanup_meta(path)
        {:error, :corrupted}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @impl true
  def put(key, %Entry{} = entry) do
    init()
    meta_path = meta_path(key)
    tmp_path = meta_path <> ".tmp." <> Integer.to_string(:erlang.unique_integer([:positive]))
    content = Entry.to_map(entry) |> Jason.encode!(pretty: true)

    case File.write(tmp_path, content) do
      :ok ->
        case File.rename(tmp_path, meta_path) do
          :ok ->
            :ok

          {:error, _} ->
            File.rm(tmp_path)
            :ok
        end

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  @impl true
  def delete(key) do
    path = meta_path(key)
    File.rm(path)
    :ok
  end

  @impl true
  def exists?(key) do
    File.exists?(meta_path(key))
  end

  @impl true
  def list_keys do
    init()

    Path.wildcard(Path.join(meta_dir(), "*.json"))
    |> Enum.map(&Path.basename(&1, ".json"))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # BLOB OPERATIONS
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def store_blob(content) when is_binary(content) do
    init()
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    dest = blob_path(hash)

    unless File.exists?(dest) do
      tmp_path = dest <> ".tmp." <> Integer.to_string(:erlang.unique_integer([:positive]))

      case File.write(tmp_path, content) do
        :ok ->
          case File.rename(tmp_path, dest) do
            :ok -> :ok
            {:error, _} -> File.rm(tmp_path)
          end

        {:error, _} ->
          nil
      end
    end

    {:ok, hash}
  end

  @impl true
  def get_blob(hash) do
    path = blob_path(hash)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end

  @impl true
  def blob_exists?(hash) do
    File.exists?(blob_path(hash))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # STATISTICS & CLEANUP
  # ─────────────────────────────────────────────────────────────────────────────

  @impl true
  def stats do
    init()

    meta_files = Path.wildcard(Path.join(meta_dir(), "*.json"))
    blob_files = Path.wildcard(Path.join(blobs_dir(), "*"))

    meta_count = length(meta_files)
    blob_count = length(blob_files)

    blob_size =
      blob_files
      |> Enum.map(fn path ->
        case File.stat(path) do
          {:ok, %{size: size}} -> size
          _ -> 0
        end
      end)
      |> Enum.sum()

    %{
      meta_count: meta_count,
      blob_count: blob_count,
      total_size: blob_size,
      total_size_human: human_size(blob_size)
    }
  end

  @impl true
  def clean do
    File.rm_rf(meta_dir())
    File.rm_rf(blobs_dir())
    init()
    :ok
  end

  @impl true
  def clean_older_than(seconds) do
    init()
    cutoff = DateTime.utc_now() |> DateTime.add(-seconds, :second)
    meta_files = Path.wildcard(Path.join(meta_dir(), "*.json"))

    # Track which blobs are still referenced
    referenced_blobs = MapSet.new()

    {deleted, kept_blobs} =
      Enum.reduce(meta_files, {0, referenced_blobs}, fn path, {count, blobs} ->
        case read_meta(path) do
          {:ok, meta} ->
            cached_at = meta["cached_at"] || ""

            case DateTime.from_iso8601(cached_at) do
              {:ok, dt, _} ->
                if DateTime.compare(dt, cutoff) == :lt do
                  case File.rm(path) do
                    :ok -> {count + 1, blobs}
                    {:error, _} -> {count, blobs}
                  end
                else
                  output_blobs =
                    (meta["outputs"] || [])
                    |> Enum.map(& &1["blob"])
                    |> Enum.reject(&is_nil/1)
                    |> MapSet.new()

                  {count, MapSet.union(blobs, output_blobs)}
                end

              _ ->
                case File.rm(path) do
                  :ok -> {count + 1, blobs}
                  {:error, _} -> {count, blobs}
                end
            end

          {:error, _} ->
            case File.rm(path) do
              :ok -> {count + 1, blobs}
              {:error, _} -> {count, blobs}
            end
        end
      end)

    # Clean orphaned blobs
    blob_files = Path.wildcard(Path.join(blobs_dir(), "*"))

    orphaned =
      Enum.reduce(blob_files, 0, fn path, count ->
        blob_name = Path.basename(path)

        if MapSet.member?(kept_blobs, blob_name) do
          count
        else
          case File.rm(path) do
            :ok -> count + 1
            {:error, _} -> count
          end
        end
      end)

    %{meta_deleted: deleted, blobs_deleted: orphaned}
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # PUBLIC HELPERS (used by Cache facade)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Returns the cache directory path.
  """
  def get_cache_dir, do: cache_dir()

  @doc """
  Returns the full path for a meta file.
  """
  def meta_path(key), do: Path.join(meta_dir(), "#{key}.json")

  @doc """
  Returns the full path for a blob file.
  """
  def blob_path(hash), do: Path.join(blobs_dir(), hash)

  @doc """
  Reads and parses a meta file.
  """
  def read_meta(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, meta} -> {:ok, meta}
          {:error, _} -> {:error, :corrupted}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validates that all blobs referenced in a meta map exist.
  """
  def blobs_valid?(meta) do
    outputs = meta["outputs"] || []

    Enum.all?(outputs, fn output ->
      blob_hash = output["blob"]
      blob_hash && File.exists?(blob_path(blob_hash))
    end)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # PRIVATE HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp cleanup_meta(meta_path) do
    case File.rm(meta_path) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.warn("Failed to remove corrupted cache file #{meta_path}: #{inspect(reason)}")
    end
  end

  defp human_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp human_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp human_size(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp human_size(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
end
