defmodule Sykli.CLI do
  @moduledoc """
  CLI entry point for escript.
  """

  def main(args \\ []) do
    case args do
      ["cache" | cache_args] ->
        handle_cache(cache_args)

      _ ->
        run_sykli(args)
    end
  end

  defp run_sykli(args) do
    path = List.first(args) || "."

    case Sykli.run(path) do
      {:ok, results} ->
        IO.puts("\n#{IO.ANSI.green()}All tasks passed#{IO.ANSI.reset()}")

        Enum.each(results, fn {name, _} ->
          IO.puts("  ✓ #{name}")
        end)

      {:error, :no_sdk_file} ->
        IO.puts("#{IO.ANSI.red()}No sykli.go, sykli.rs, or sykli.ts found#{IO.ANSI.reset()}")
        System.halt(1)

      {:error, results} when is_list(results) ->
        IO.puts("\n#{IO.ANSI.red()}Build failed#{IO.ANSI.reset()}")
        System.halt(1)

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
        System.halt(1)
    end
  end

  # ----- CACHE SUBCOMMANDS -----

  defp handle_cache(["stats"]) do
    stats = Sykli.Cache.stats()

    IO.puts("#{IO.ANSI.cyan()}Cache Statistics#{IO.ANSI.reset()}")
    IO.puts("  Location:    #{Sykli.Cache.cache_dir()}")
    IO.puts("  Tasks:       #{stats.meta_count}")
    IO.puts("  Blobs:       #{stats.blob_count}")
    IO.puts("  Total size:  #{stats.total_size_human}")
  end

  defp handle_cache(["clean"]) do
    Sykli.Cache.clean()
    IO.puts("#{IO.ANSI.green()}Cache cleaned#{IO.ANSI.reset()}")
  end

  defp handle_cache(["clean", "--older-than", duration]) do
    case parse_duration(duration) do
      {:ok, seconds} ->
        result = Sykli.Cache.clean_older_than(seconds)

        IO.puts(
          "#{IO.ANSI.green()}Cleaned #{result.meta_deleted} task(s) and #{result.blobs_deleted} blob(s)#{IO.ANSI.reset()}"
        )

      {:error, _} ->
        IO.puts("#{IO.ANSI.red()}Invalid duration: #{duration}#{IO.ANSI.reset()}")
        IO.puts("Examples: 7d, 24h, 30m")
        System.halt(1)
    end
  end

  defp handle_cache(["path"]) do
    IO.puts(Sykli.Cache.cache_dir())
  end

  defp handle_cache(_) do
    IO.puts("Usage: sykli cache <command>")
    IO.puts("")
    IO.puts("Commands:")
    IO.puts("  stats                 Show cache statistics")
    IO.puts("  clean                 Delete all cached data")
    IO.puts("  clean --older-than N  Delete cache older than N (e.g., 7d, 24h)")
    IO.puts("  path                  Print cache directory path")
  end

  # Parse duration like "7d", "24h", "30m" into seconds
  defp parse_duration(str) do
    case Regex.run(~r/^(\d+)(d|h|m)$/, str) do
      [_, num, "d"] -> {:ok, String.to_integer(num) * 86400}
      [_, num, "h"] -> {:ok, String.to_integer(num) * 3600}
      [_, num, "m"] -> {:ok, String.to_integer(num) * 60}
      _ -> {:error, :invalid}
    end
  end
end
