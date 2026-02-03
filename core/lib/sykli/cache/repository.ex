defmodule Sykli.Cache.Repository do
  @moduledoc """
  Behaviour defining the cache repository interface.

  A cache repository manages storage and retrieval of task execution results.
  The default implementation is `Sykli.Cache.FileRepository`, which stores
  cache entries on the local filesystem.

  ## Implementation

      defmodule MyCache.Repository do
        @behaviour Sykli.Cache.Repository

        @impl true
        def get(key) do
          # Retrieve entry by key
        end

        # ... implement other callbacks
      end
  """

  alias Sykli.Cache.Entry

  @type key :: String.t()
  @type miss_reason ::
          :no_cache
          | :command_changed
          | :inputs_changed
          | :container_changed
          | :env_changed
          | :mounts_changed
          | :config_changed
          | :corrupted
          | :blobs_missing

  @doc """
  Retrieves a cache entry by key.

  Returns `{:ok, entry}` if found, or `{:error, reason}` if not found or corrupted.
  """
  @callback get(key) :: {:ok, Entry.t()} | {:error, :not_found | :corrupted}

  @doc """
  Stores a cache entry with the given key.

  Returns `:ok` on success, or `{:error, reason}` on failure.
  """
  @callback put(key, Entry.t()) :: :ok | {:error, term()}

  @doc """
  Deletes a cache entry by key.

  Returns `:ok` regardless of whether the entry existed.
  """
  @callback delete(key) :: :ok

  @doc """
  Checks if a cache entry exists for the given key.
  """
  @callback exists?(key) :: boolean()

  @doc """
  Lists all cache keys.
  """
  @callback list_keys() :: [key]

  @doc """
  Stores a blob (output file content) and returns its hash.

  Returns `{:ok, hash}` on success.
  """
  @callback store_blob(binary()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Retrieves a blob by its hash.

  Returns `{:ok, content}` if found.
  """
  @callback get_blob(String.t()) :: {:ok, binary()} | {:error, :not_found}

  @doc """
  Checks if a blob exists for the given hash.
  """
  @callback blob_exists?(String.t()) :: boolean()

  @doc """
  Initializes the repository (creates directories, etc.).
  """
  @callback init() :: :ok | {:error, term()}

  @doc """
  Returns repository statistics.
  """
  @callback stats() :: %{
              meta_count: non_neg_integer(),
              blob_count: non_neg_integer(),
              total_size: non_neg_integer(),
              total_size_human: String.t()
            }

  @doc """
  Cleans all cache entries.
  """
  @callback clean() :: :ok

  @doc """
  Cleans cache entries older than the given number of seconds.

  Returns `%{meta_deleted: count, blobs_deleted: count}`.
  """
  @callback clean_older_than(non_neg_integer()) :: %{
              meta_deleted: non_neg_integer(),
              blobs_deleted: non_neg_integer()
            }
end
