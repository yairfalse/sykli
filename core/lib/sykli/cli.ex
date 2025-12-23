defmodule Sykli.CLI do
  @moduledoc """
  CLI entry point for escript.
  """

  @version Mix.Project.config()[:version]

  def main(args \\ []) do
    case args do
      [flag] when flag in ["--help", "-h"] ->
        print_help()
        halt(0)

      [flag] when flag in ["--version", "-v"] ->
        IO.puts("sykli #{@version}")
        halt(0)

      ["cache" | cache_args] ->
        handle_cache(cache_args)
        halt(0)

      _ ->
        run_sykli(args)
    end
  end

  defp print_help do
    IO.puts("""
    sykli - CI pipelines in your language

    Usage: sykli [path]
           sykli cache <command>

    Options:
      -h, --help       Show this help
      -v, --version    Show version

    Commands:
      sykli [path]     Run pipeline (default: current directory)
      sykli cache      Manage cache (see: sykli cache --help)

    Examples:
      sykli                    Run pipeline in current directory
      sykli ./my-project       Run pipeline in ./my-project
      sykli cache stats        Show cache statistics
    """)
  end

  defp run_sykli(args) do
    path = List.first(args) || "."
    start_time = System.monotonic_time(:millisecond)

    case Sykli.run(path) do
      {:ok, results} ->
        duration = System.monotonic_time(:millisecond) - start_time
        IO.puts("\n#{IO.ANSI.green()}✓ All tasks completed in #{format_duration(duration)}#{IO.ANSI.reset()}")

        # Results are {name, result, duration} tuples
        Enum.each(results, fn {name, _, _} ->
          IO.puts("  ✓ #{name}")
        end)

        halt(0)

      {:error, :no_sdk_file} ->
        IO.puts("#{IO.ANSI.red()}No sykli.go, sykli.rs, or sykli.ts found#{IO.ANSI.reset()}")
        halt(1)

      {:error, results} when is_list(results) ->
        IO.puts("\n#{IO.ANSI.red()}Build failed#{IO.ANSI.reset()}")
        halt(1)

      {:error, {:cycle_detected, path}} when is_list(path) and length(path) > 0 ->
        cycle_str = Enum.join(path, " -> ")
        IO.puts("#{IO.ANSI.red()}Error: dependency cycle detected: #{cycle_str}#{IO.ANSI.reset()}")
        halt(1)

      {:error, {:cycle_detected, _}} ->
        IO.puts("#{IO.ANSI.red()}Error: dependency cycle detected#{IO.ANSI.reset()}")
        halt(1)

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
        halt(1)
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
    Sykli.Cache.init()
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
        IO.puts("Examples: 7d, 24h, 30m, 60s")
        halt(1)
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
    IO.puts("  clean --older-than <duration>  Delete cache older than <duration> (e.g., 7d, 24h, 30m)")
    IO.puts("  path                  Print cache directory path")
  end

  # Parse duration like "7d", "24h", "30m", "60s" into seconds
  defp parse_duration(str) do
    case Regex.run(~r/^(\d+)(d|h|m|s)$/, str) do
      [_, num, "d"] -> {:ok, String.to_integer(num) * 86400}
      [_, num, "h"] -> {:ok, String.to_integer(num) * 3600}
      [_, num, "m"] -> {:ok, String.to_integer(num) * 60}
      [_, num, "s"] -> {:ok, String.to_integer(num)}
      _ -> {:error, :invalid}
    end
  end

  # Format milliseconds as human readable duration
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) do
    seconds = ms / 1000
    "#{Float.round(seconds, 1)}s"
  end

  # Halt with proper stdout flushing (needed for Burrito releases)
  defp halt(code) do
    :erlang.halt(code, [{:flush, true}])
  end
end
