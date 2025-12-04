defmodule Sykli.Cache do
  @moduledoc """
  Content-addressed caching for task results.
  Skip tasks when inputs haven't changed.
  """

  @cache_dir Path.expand("~/.sykli/cache")

  def init do
    File.mkdir_p!(@cache_dir)
  end

  @doc """
  Check if task can be skipped (cache hit).
  Returns {:hit, cached_result} or :miss
  """
  def check(task_name, inputs, workdir) do
    key = cache_key(task_name, inputs, workdir)
    path = cache_path(key)

    if File.exists?(path) do
      {:hit, key}
    else
      {:miss, key}
    end
  end

  @doc """
  Store successful task result in cache.
  """
  def store(key) do
    path = cache_path(key)
    File.write!(path, "ok")
  end

  @doc """
  Generate cache key from task name and input file hashes.
  """
  def cache_key(task_name, inputs, workdir) do
    input_hash = hash_inputs(inputs, workdir)
    :crypto.hash(:sha256, "#{task_name}:#{input_hash}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # Hash all files matching input globs
  defp hash_inputs(inputs, workdir) do
    inputs
    |> Enum.flat_map(fn pattern ->
      Path.wildcard(Path.join(workdir, pattern))
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

  defp cache_path(key) do
    Path.join(@cache_dir, key)
  end
end
