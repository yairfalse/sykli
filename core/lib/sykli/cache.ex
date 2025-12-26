defmodule Sykli.Cache do
  @moduledoc """
  Content-addressed caching for task results.

  Cache key includes: task name, command, input files hash, env vars, sykli version.
  Outputs are stored as content-addressed blobs for deduplication.

  Structure:
    ~/.sykli/cache/
    ├── meta/
    │   └── <key>.json          # task metadata
    └── blobs/
        └── <sha256>            # content-addressed files
  """

  @cache_dir Path.expand("~/.sykli/cache")
  @meta_dir Path.join(@cache_dir, "meta")
  @blobs_dir Path.join(@cache_dir, "blobs")
  @version "0.1.0"

  # Env vars that affect builds (PATH excluded - too volatile)
  @relevant_env_vars ["GOPATH", "GOROOT", "CARGO_HOME", "NODE_ENV", "GOOS", "GOARCH"]

  def init do
    File.mkdir_p!(@meta_dir)
    File.mkdir_p!(@blobs_dir)
  end

  def cache_dir, do: @cache_dir

  @doc """
  Check if task can be skipped (cache hit).
  Returns {:hit, key} or {:miss, key}
  """
  def check(task, workdir) do
    case check_detailed(task, workdir) do
      {:hit, key} -> {:hit, key}
      {:miss, key, _reason} -> {:miss, key}
    end
  end

  @doc """
  Check if task can be skipped, with detailed miss reason.

  Returns:
    - {:hit, key} - cache hit, can skip
    - {:miss, key, reason} - cache miss with reason

  Reasons:
    - :no_cache - no cache entry exists for this task
    - :command_changed - command differs from cached
    - :inputs_changed - input files have changed
    - :container_changed - container image changed
    - :env_changed - task environment changed
    - :corrupted - meta file is corrupted
    - :blobs_missing - output blobs are missing
  """
  def check_detailed(task, workdir) do
    key = cache_key(task, workdir)
    meta_path = meta_path(key)
    abs_workdir = Path.expand(workdir)

    case read_meta(meta_path) do
      {:ok, meta} ->
        # Verify all blobs exist
        if blobs_valid?(meta) do
          {:hit, key}
        else
          # Corrupted cache - clean up
          cleanup_meta(meta_path)
          {:miss, key, :blobs_missing}
        end

      {:error, :corrupted} ->
        cleanup_meta(meta_path)
        {:miss, key, :corrupted}

      {:error, _} ->
        # No cache entry - try to find why by looking for other entries with same task name
        find_miss_reason(task, abs_workdir, key)
    end
  end

  # Find the reason for cache miss by comparing with existing entries
  defp find_miss_reason(task, workdir, current_key) do
    # Look for any meta file for this task name
    meta_files = Path.wildcard(Path.join(@meta_dir, "*.json"))

    matching_entry = Enum.find_value(meta_files, fn path ->
      case read_meta(path) do
        {:ok, meta} ->
          if meta["task_name"] == task.name, do: meta, else: nil
        _ ->
          nil
      end
    end)

    case matching_entry do
      nil ->
        {:miss, current_key, :no_cache}

      cached_meta ->
        # Compare individual components to find what changed
        reason = determine_change_reason(task, cached_meta, workdir)
        {:miss, current_key, reason}
    end
  end

  # Determine what changed between current task and cached metadata
  defp determine_change_reason(task, cached_meta, workdir) do
    cond do
      task.command != cached_meta["command"] ->
        :command_changed

      hash_inputs(task.inputs || [], workdir) != cached_meta["inputs_hash"] ->
        :inputs_changed

      (task.container || "") != (cached_meta["container"] || "") ->
        :container_changed

      hash_task_env(task.env || %{}) != (cached_meta["env_hash"] || "") ->
        :env_changed

      hash_mounts(task.mounts || []) != (cached_meta["mounts_hash"] || "") ->
        :mounts_changed

      true ->
        # Fallback - something else changed (maybe version)
        :config_changed
    end
  end

  defp cleanup_meta(meta_path) do
    case File.rm(meta_path) do
      :ok -> :ok
      {:error, reason} ->
        IO.warn("Failed to remove corrupted cache file #{meta_path}: #{inspect(reason)}")
    end
  end

  @doc """
  Format a cache miss reason for display.
  """
  def format_miss_reason(:no_cache), do: "first run"
  def format_miss_reason(:command_changed), do: "command changed"
  def format_miss_reason(:inputs_changed), do: "inputs changed"
  def format_miss_reason(:container_changed), do: "container changed"
  def format_miss_reason(:env_changed), do: "env changed"
  def format_miss_reason(:mounts_changed), do: "mounts changed"
  def format_miss_reason(:corrupted), do: "cache corrupted"
  def format_miss_reason(:blobs_missing), do: "outputs missing"
  def format_miss_reason(:config_changed), do: "config changed"
  def format_miss_reason(other), do: "#{other}"

  @doc """
  Restore cached outputs to workdir.
  Returns :ok or {:error, reason}
  """
  def restore(key, workdir) do
    meta_path = meta_path(key)

    case read_meta(meta_path) do
      {:ok, meta} ->
        restore_outputs(meta["outputs"] || [], workdir)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Store task outputs in cache.
  Returns :ok or {:error, reason}
  """
  def store(key, task, outputs, duration_ms, workdir) do
    abs_workdir = Path.expand(workdir)

    # Collect output file info
    output_entries =
      outputs
      |> Enum.flat_map(fn pattern ->
        expand_output_pattern(pattern, abs_workdir)
      end)
      |> Enum.map(fn path ->
        store_blob(path, abs_workdir)
      end)
      |> Enum.reject(&is_nil/1)

    # Check if any outputs were expected but missing
    if outputs != [] && output_entries == [] do
      IO.puts(
        "#{IO.ANSI.yellow()}⚠ Warning: No output files found for task #{task.name}#{IO.ANSI.reset()}"
      )
    end

    meta = %{
      "task_name" => task.name,
      "command" => task.command,
      "outputs" => output_entries,
      "duration_ms" => duration_ms,
      "cached_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "inputs_hash" => hash_inputs(task.inputs || [], abs_workdir),
      "container" => task.container || "",
      "env_hash" => hash_task_env(task.env || %{}),
      "mounts_hash" => hash_mounts(task.mounts || []),
      "sykli_version" => @version
    }

    meta_path = meta_path(key)
    # Atomic write: write to temp file then rename
    tmp_path = meta_path <> ".tmp." <> Integer.to_string(:erlang.unique_integer([:positive]))
    File.write!(tmp_path, Jason.encode!(meta, pretty: true))

    case File.rename(tmp_path, meta_path) do
      :ok ->
        :ok

      {:error, _} ->
        File.rm(tmp_path)
        :ok
    end
  end

  @doc """
  Get cache statistics.
  """
  def stats do
    init()

    meta_files = Path.wildcard(Path.join(@meta_dir, "*.json"))
    blob_files = Path.wildcard(Path.join(@blobs_dir, "*"))

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

  @doc """
  Clean all cache entries.
  """
  def clean do
    File.rm_rf!(@meta_dir)
    File.rm_rf!(@blobs_dir)
    init()
    :ok
  end

  @doc """
  Clean cache entries older than given duration.
  Duration is in seconds.
  """
  def clean_older_than(seconds) do
    init()
    cutoff = DateTime.utc_now() |> DateTime.add(-seconds, :second)
    meta_files = Path.wildcard(Path.join(@meta_dir, "*.json"))

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
                    :ok ->
                      {count + 1, blobs}

                    {:error, reason} ->
                      IO.warn("Failed to remove cache file #{path}: #{inspect(reason)}")
                      {count, blobs}
                  end
                else
                  # Keep track of blobs still in use
                  output_blobs =
                    (meta["outputs"] || [])
                    |> Enum.map(& &1["blob"])
                    |> Enum.reject(&is_nil/1)
                    |> MapSet.new()

                  {count, MapSet.union(blobs, output_blobs)}
                end

              _ ->
                # Invalid date, delete
                case File.rm(path) do
                  :ok ->
                    {count + 1, blobs}

                  {:error, reason} ->
                    IO.warn("Failed to remove invalid cache file #{path}: #{inspect(reason)}")
                    {count, blobs}
                end
            end

          {:error, _} ->
            case File.rm(path) do
              :ok ->
                {count + 1, blobs}

              {:error, reason} ->
                IO.warn("Failed to remove unreadable cache file #{path}: #{inspect(reason)}")
                {count, blobs}
            end
        end
      end)

    # Clean orphaned blobs
    blob_files = Path.wildcard(Path.join(@blobs_dir, "*"))

    orphaned =
      Enum.reduce(blob_files, 0, fn path, count ->
        blob_name = Path.basename(path)

        if MapSet.member?(kept_blobs, blob_name) do
          count
        else
          case File.rm(path) do
            :ok ->
              count + 1

            {:error, reason} ->
              IO.warn("Failed to remove blob #{path}: #{inspect(reason)}")
              count
          end
        end
      end)

    %{meta_deleted: deleted, blobs_deleted: orphaned}
  end

  # ----- CACHE KEY GENERATION -----

  @doc """
  Generate cache key from all factors that affect output.
  Includes v2 fields: container, task env, mounts.
  """
  def cache_key(task, workdir) do
    abs_workdir = Path.expand(workdir)
    inputs_hash = hash_inputs(task.inputs || [], abs_workdir)
    env_hash = hash_env()

    # v2 fields that affect build output
    container = task.container || ""
    task_env_hash = hash_task_env(task.env || %{})
    mounts_hash = hash_mounts(task.mounts || [])

    data =
      Enum.join(
        [
          task.name,
          task.command,
          inputs_hash,
          env_hash,
          container,
          task_env_hash,
          mounts_hash,
          @version
        ],
        "|"
      )

    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  # Hash task-specific environment variables
  defp hash_task_env(env) when map_size(env) == 0, do: ""

  defp hash_task_env(env) do
    env
    |> Enum.sort()
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join("|")
    |> then(fn data -> :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) end)
  end

  # Hash mount configuration (resource + path + type)
  defp hash_mounts([]), do: ""

  defp hash_mounts(mounts) do
    mounts
    |> Enum.map(fn m -> "#{m[:resource]}:#{m[:path]}:#{m[:type]}" end)
    |> Enum.sort()
    |> Enum.join("|")
    |> then(fn data -> :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) end)
  end

  # ----- PRIVATE HELPERS -----

  defp hash_inputs(inputs, workdir) do
    inputs
    |> Enum.flat_map(fn pattern ->
      Path.wildcard(Path.join(workdir, pattern), match_dot: false)
    end)
    |> Enum.sort()
    |> Enum.map(&hash_file/1)
    |> Enum.join("")
    |> then(fn content ->
      :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    end)
  end

  defp hash_file(path) do
    case File.read(path) do
      {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      _ -> ""
    end
  end

  defp hash_env do
    @relevant_env_vars
    |> Enum.map(fn var -> "#{var}=#{System.get_env(var) || ""}" end)
    |> Enum.join("|")
    |> then(fn data -> :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) end)
  end

  defp meta_path(key) do
    Path.join(@meta_dir, "#{key}.json")
  end

  defp blob_path(hash) do
    Path.join(@blobs_dir, hash)
  end

  defp read_meta(path) do
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

  defp blobs_valid?(meta) do
    outputs = meta["outputs"] || []

    Enum.all?(outputs, fn output ->
      blob_hash = output["blob"]
      blob_hash && File.exists?(blob_path(blob_hash))
    end)
  end

  defp expand_output_pattern(pattern, workdir) do
    full_path = Path.join(workdir, pattern)

    cond do
      # Exact file
      File.regular?(full_path) ->
        [full_path]

      # Directory - recursively get all files
      File.dir?(full_path) ->
        Path.wildcard(Path.join(full_path, "**/*"), match_dot: false)
        |> Enum.filter(&File.regular?/1)

      # Glob pattern
      String.contains?(pattern, ["*", "?", "["]) ->
        Path.wildcard(full_path, match_dot: false)
        |> Enum.filter(&File.regular?/1)

      # File doesn't exist
      true ->
        []
    end
  end

  defp store_blob(abs_path, workdir) do
    case File.read(abs_path) do
      {:ok, content} ->
        blob_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
        dest = blob_path(blob_hash)

        # Atomically write blob to avoid race conditions
        unless File.exists?(dest) do
          tmp_path = dest <> ".tmp." <> Integer.to_string(:erlang.unique_integer([:positive]))
          File.write!(tmp_path, content)

          case File.rename(tmp_path, dest) do
            :ok -> :ok
            # Another process won the race
            {:error, :eexist} -> File.rm(tmp_path)
            # Clean up temp file on error
            {:error, _} -> File.rm(tmp_path)
          end
        end

        # Get file mode
        mode =
          case File.stat(abs_path) do
            {:ok, %{mode: m}} -> m
            _ -> 0o644
          end

        size = byte_size(content)
        rel_path = Path.relative_to(abs_path, workdir)

        %{
          "path" => rel_path,
          "blob" => blob_hash,
          "mode" => mode,
          "size" => size
        }

      {:error, _} ->
        nil
    end
  end

  defp restore_outputs(outputs, workdir) do
    abs_workdir = Path.expand(workdir)

    results =
      Enum.map(outputs, fn output ->
        restore_single_output(output, abs_workdir)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      error -> error
    end
  end

  defp restore_single_output(output, workdir) do
    rel_path = output["path"]
    blob_hash = output["blob"]
    mode = output["mode"] || 0o644

    dest_path = Path.join(workdir, rel_path)
    src_path = blob_path(blob_hash)

    # Ensure parent directory exists
    dest_path |> Path.dirname() |> File.mkdir_p!()

    case File.read(src_path) do
      {:ok, content} ->
        File.write!(dest_path, content)
        File.chmod!(dest_path, mode)
        :ok

      {:error, reason} ->
        {:error, {:blob_missing, blob_hash, reason}}
    end
  end

  defp human_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp human_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp human_size(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp human_size(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
end
