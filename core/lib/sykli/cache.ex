defmodule Sykli.Cache do
  @moduledoc """
  Content-addressed caching for task results.

  This module serves as a facade over the cache repository, providing
  high-level caching operations for the executor.

  Cache key includes: task name, command, input files hash, env vars, sykli version.
  Outputs are stored as content-addressed blobs for deduplication.

  Structure:
    ~/.sykli/cache/
    ├── meta/
    │   └── <key>.json          # task metadata
    └── blobs/
        └── <sha256>            # content-addressed files
  """

  alias Sykli.Cache.Entry
  alias Sykli.Cache.FileRepository, as: Repo

  @version "0.1.0"

  # Env vars that affect builds (PATH excluded - too volatile)
  @relevant_env_vars ["GOPATH", "GOROOT", "CARGO_HOME", "NODE_ENV", "GOOS", "GOARCH"]

  def init, do: Repo.init()

  def get_cache_dir, do: Repo.get_cache_dir()

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
    - :mounts_changed - task mounts have changed
    - :config_changed - task configuration has changed
    - :corrupted - meta file is corrupted
    - :blobs_missing - output blobs are missing
  """
  def check_detailed(task, workdir) do
    key = cache_key(task, workdir)
    meta_path = Repo.meta_path(key)
    abs_workdir = Path.expand(workdir)

    case Repo.read_meta(meta_path) do
      {:ok, meta} ->
        # Verify all blobs exist
        if Repo.blobs_valid?(meta) do
          {:hit, key}
        else
          # Corrupted cache - clean up
          Repo.delete(key)
          {:miss, key, :blobs_missing}
        end

      {:error, :corrupted} ->
        Repo.delete(key)
        {:miss, key, :corrupted}

      {:error, _} ->
        # No cache entry - try to find why by looking for other entries with same task name
        find_miss_reason(task, abs_workdir, key)
    end
  end

  # Find the reason for cache miss by comparing with existing entries
  defp find_miss_reason(task, workdir, current_key) do
    # Look for any meta file for this task name
    matching_entry =
      Repo.list_keys()
      |> Enum.find_value(fn key ->
        case Repo.get(key) do
          {:ok, entry} ->
            if entry.task_name == task.name, do: entry, else: nil

          _ ->
            nil
        end
      end)

    case matching_entry do
      nil ->
        {:miss, current_key, :no_cache}

      cached_entry ->
        # Compare individual components to find what changed
        reason = determine_change_reason(task, cached_entry, workdir)
        {:miss, current_key, reason}
    end
  end

  # Determine what changed between current task and cached entry
  defp determine_change_reason(task, %Entry{} = cached, workdir) do
    cond do
      task.command != cached.command ->
        :command_changed

      hash_inputs(task.inputs || [], workdir) != cached.inputs_hash ->
        :inputs_changed

      (task.container || "") != (cached.container || "") ->
        :container_changed

      hash_task_env(task.env || %{}) != (cached.env_hash || "") ->
        :env_changed

      hash_mounts(task.mounts || []) != (cached.mounts_hash || "") ->
        :mounts_changed

      true ->
        # Fallback - something else changed (maybe version)
        :config_changed
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
    case Repo.get(key) do
      {:ok, entry} ->
        restore_outputs(entry.outputs || [], workdir)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Store task outputs in cache.
  Returns :ok or {:error, reason}
  """
  def store(key, task, outputs, duration_ms, workdir) do
    Repo.init()
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

    entry =
      Entry.new(%{
        task_name: task.name,
        command: task.command,
        outputs: output_entries,
        duration_ms: duration_ms,
        cached_at: DateTime.utc_now(),
        inputs_hash: hash_inputs(task.inputs || [], abs_workdir),
        container: task.container || "",
        env_hash: hash_task_env(task.env || %{}),
        mounts_hash: hash_mounts(task.mounts || []),
        sykli_version: @version
      })

    Repo.put(key, entry)
  end

  @doc """
  Get cache statistics.
  """
  def stats, do: Repo.stats()

  @doc """
  Clean all cache entries.
  """
  def clean, do: Repo.clean()

  @doc """
  Clean cache entries older than given duration.
  Duration is in seconds.
  """
  def clean_older_than(seconds), do: Repo.clean_older_than(seconds)

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

  # ----- PRIVATE HELPERS -----

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
        {:ok, blob_hash} = Repo.store_blob(content)

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

    case Repo.get_blob(blob_hash) do
      {:ok, content} ->
        with :ok <- dest_path |> Path.dirname() |> File.mkdir_p(),
             :ok <- File.write(dest_path, content),
             :ok <- File.chmod(dest_path, mode) do
          :ok
        else
          {:error, reason} -> {:error, {:restore_failed, rel_path, reason}}
        end

      {:error, _} ->
        {:error, {:restore_failed, rel_path, :blob_not_found}}
    end
  end
end
