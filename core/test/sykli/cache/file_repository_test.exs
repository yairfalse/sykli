defmodule Sykli.Cache.FileRepositoryTest do
  use ExUnit.Case, async: false

  alias Sykli.Cache.FileRepository

  test "store_blob returns write errors instead of reporting a missing blob as stored" do
    old_cache_dir = Application.get_env(:sykli, :cache_dir)

    cache_dir =
      Path.join(System.tmp_dir!(), "sykli-cache-file-repo-#{System.unique_integer([:positive])}")

    blobs_path = Path.join(cache_dir, "blobs")

    try do
      Application.put_env(:sykli, :cache_dir, cache_dir)
      File.mkdir_p!(Path.dirname(blobs_path))
      File.write!(blobs_path, "not a directory")

      assert {:error, :enotdir} = FileRepository.store_blob("content")
    after
      restore_cache_dir(old_cache_dir)
      File.rm_rf(cache_dir)
    end
  end

  defp restore_cache_dir(nil), do: Application.delete_env(:sykli, :cache_dir)
  defp restore_cache_dir(cache_dir), do: Application.put_env(:sykli, :cache_dir, cache_dir)
end
