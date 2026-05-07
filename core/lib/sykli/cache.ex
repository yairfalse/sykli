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

  ## Project identity

  A project's identity is a SHA256 fingerprint of its origin. For projects inside
  a git repository with an origin remote, the fingerprint is derived from
  "git:<origin_url>|<repo_relative_workdir>". For projects without git or without
  an origin remote, the fingerprint is derived from "path:<absolute_path>".

  Consequences:
  - Two subdirectories of the same monorepo have different fingerprints.
  - The same project cloned to different absolute paths shares a fingerprint
    (origin URL wins).
  - Moving a non-git project to a different path invalidates its cache.
  - Changing this scheme requires bumping `cache_key_version` in
    `task_cached` and `cache_miss` occurrence payloads.
  """

  alias Sykli.Cache.Entry
  alias Sykli.Cache.FileRepository, as: Repo

  @version "0.1.0"

  defp repo do
    bucket = System.get_env("SYKLI_CACHE_S3_BUCKET")
    access = System.get_env("SYKLI_CACHE_S3_ACCESS_KEY")
    secret = System.get_env("SYKLI_CACHE_S3_SECRET_KEY")

    if bucket != nil and access != nil and secret != nil do
      Sykli.Cache.TieredRepository
    else
      Sykli.Cache.FileRepository
    end
  end

  # Env vars that affect builds (PATH excluded - too volatile)
  @relevant_env_vars ["GOPATH", "GOROOT", "CARGO_HOME", "NODE_ENV", "GOOS", "GOARCH"]

  def init, do: repo().init()

  def get_cache_dir, do: Sykli.Cache.FileRepository.get_cache_dir()

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

  def format_miss_reason(:success_criteria_requires_execution),
    do: "success criteria require execution"

  def format_miss_reason(other), do: "#{other}"

  @doc """
  Restore cached outputs to workdir.
  Returns :ok or {:error, reason}
  """
  def restore(key, workdir) do
    case repo().get(key) do
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
    repo().init()
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

    repo().put(key, entry)
  end

  @doc """
  Look up a cache entry by key.
  Returns {:ok, Cache.Entry.t()} or {:error, reason}.
  """
  def get_entry(key), do: repo().get(key)

  @doc """
  Get cache statistics.
  """
  def stats, do: repo().stats()

  @doc """
  Clean all cache entries.
  """
  def clean, do: repo().clean()

  @doc """
  Clean cache entries older than given duration.
  Duration is in seconds.
  """
  def clean_older_than(seconds), do: repo().clean_older_than(seconds)

  # ----- CACHE KEY GENERATION -----

  @doc """
  Generate cache key from all factors that affect output.
  Includes v2 fields (container, task env, mounts) and v3 project fingerprint.
  """
  def cache_key(task, workdir) do
    abs_workdir = Path.expand(workdir)
    inputs_hash = hash_inputs(task.inputs || [], abs_workdir)
    env_hash = hash_env()

    # v2 fields that affect build output
    container = task.container || ""
    task_env_hash = hash_task_env(task.env || %{})
    mounts_hash = hash_mounts(task.mounts || [])

    # v3: project fingerprint prevents cross-project cache pollution.
    # Uses git remote URL (same repo on different machines shares cache)
    # or falls back to workdir hash (non-git projects scoped by directory).
    fingerprint = project_fingerprint(abs_workdir)

    # Include secret_refs names in cache key so credential rotation causes cache miss
    secret_refs_hash = hash_secret_refs(task.secret_refs || [])

    data =
      Enum.join(
        [
          fingerprint,
          task.name,
          task.command,
          inputs_hash,
          env_hash,
          container,
          task_env_hash,
          mounts_hash,
          secret_refs_hash,
          @version
        ],
        "|"
      )

    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  # ----- PROJECT FINGERPRINT -----

  # Generates a stable project identity for cache scoping.
  # Priority: git remote URL > absolute workdir path.
  # This ensures different projects get different cache keys even if
  # their task names and commands are identical.
  # Memoized per workdir via :persistent_term to avoid shelling out to git
  # on every cache key computation.
  @doc false
  def project_fingerprint(workdir) do
    abs_workdir = Path.expand(workdir)
    key = {:sykli_project_fingerprint, abs_workdir}

    case safe_persistent_get(key) do
      {:ok, fingerprint} ->
        fingerprint

      :error ->
        fingerprint = compute_fingerprint(abs_workdir)
        :persistent_term.put(key, fingerprint)
        fingerprint
    end
  end

  @doc false
  def project_root(workdir) do
    abs_workdir = Path.expand(workdir)
    find_project_root(abs_workdir, abs_workdir)
  end

  defp safe_persistent_get(key) do
    {:ok, :persistent_term.get(key)}
  rescue
    ArgumentError -> :error
  end

  defp compute_fingerprint(workdir) do
    case project_root(workdir) do
      {:git, origin_url, root_path} ->
        relative = Path.relative_to(workdir, root_path)
        hash_fingerprint_input("git:#{origin_url}|#{relative}")

      {:non_git, absolute_path} ->
        hash_fingerprint_input("path:#{absolute_path}")
    end
  end

  defp hash_fingerprint_input(input) do
    :crypto.hash(:sha256, input)
    |> Base.encode16(case: :lower)
  end

  defp find_project_root(path, original_workdir) do
    git_path = Path.join(path, ".git")

    cond do
      File.dir?(git_path) ->
        case read_git_origin(git_path) do
          {:ok, origin_url} -> {:git, origin_url, path}
          :error -> {:non_git, original_workdir}
        end

      File.regular?(git_path) ->
        case resolve_gitdir(git_path) do
          {:ok, gitdir} ->
            case read_git_origin(gitdir) do
              {:ok, origin_url} -> {:git, origin_url, path}
              :error -> {:non_git, original_workdir}
            end

          :error ->
            {:non_git, original_workdir}
        end

      true ->
        parent = Path.dirname(path)

        if parent == path do
          {:non_git, original_workdir}
        else
          find_project_root(parent, original_workdir)
        end
    end
  end

  defp resolve_gitdir(git_file_path) do
    with {:ok, content} <- File.read(git_file_path),
         [gitdir] <- Regex.run(~r/^gitdir:\s*(.+)\s*$/m, content, capture: :all_but_first) do
      {:ok, Path.expand(gitdir, Path.dirname(git_file_path))}
    else
      _ -> :error
    end
  end

  defp read_git_origin(git_dir) do
    config_path = Path.join(git_dir, "config")

    with {:ok, config} <- File.read(config_path),
         {:ok, origin_url} <- parse_origin_url(config) do
      {:ok, origin_url}
    else
      _ -> :error
    end
  end

  defp parse_origin_url(config) do
    config
    |> String.split("\n")
    |> Enum.reduce_while(false, fn line, in_origin ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, "[") ->
          {:cont, trimmed == ~s([remote "origin"])}

        not in_origin ->
          {:cont, in_origin}

        true ->
          case Regex.run(~r/^url\s*=\s*(.+)$/i, trimmed, capture: :all_but_first) do
            [url] when url != "" -> {:halt, {:ok, String.trim(url)}}
            _ -> {:cont, in_origin}
          end
      end
    end)
    |> case do
      {:ok, origin_url} -> {:ok, origin_url}
      _ -> :error
    end
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
  defp hash_secret_refs([]), do: ""

  defp hash_secret_refs(refs) do
    refs
    |> Enum.map(fn r -> "#{r[:name]}:#{r[:source]}:#{r[:key]}" end)
    |> Enum.sort()
    |> Enum.join("|")
    |> then(fn data -> :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) end)
  end

  defp hash_mounts([]), do: ""

  defp hash_mounts(mounts) do
    mounts
    |> Enum.map(fn m -> "#{m[:resource]}:#{m[:path]}:#{m[:type]}" end)
    |> Enum.sort()
    |> Enum.join("|")
    |> then(fn data -> :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) end)
  end

  # Maximum file size for content hashing (100 MB). Files larger than this
  # use metadata-only hashing (path + mtime + size) to avoid excessive I/O.
  @max_hash_file_size 100 * 1024 * 1024

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
    case File.stat(path, time: :posix) do
      {:ok, %{size: size}} when size > @max_hash_file_size ->
        # Oversized file: use metadata hash to avoid excessive I/O
        hash_file_metadata(path)

      {:ok, %{size: size}} when size == 0 ->
        hash_file_metadata(path)

      {:ok, _stat} ->
        # Stream file content for hash to avoid loading into memory
        hash_file_streaming(path)

      {:error, _} ->
        ""
    end
  end

  defp hash_file_streaming(path) do
    path
    |> File.stream!([], 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  rescue
    _ -> hash_file_metadata(path)
  end

  defp hash_file_metadata(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{size: size, mtime: mtime}} ->
        :crypto.hash(:sha256, "#{path}:#{mtime}:#{size}")
        |> Base.encode16(case: :lower)

      {:error, _} ->
        ""
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
        {:ok, blob_hash} = repo().store_blob(content)

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

    case repo().get_blob(blob_hash) do
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
