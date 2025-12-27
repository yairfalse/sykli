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

      ["graph" | graph_args] ->
        handle_graph(graph_args)

      ["delta" | delta_args] ->
        handle_delta(delta_args)

      # Support explicit 'run' command: sykli run [path]
      ["run" | run_args] ->
        run_sykli(run_args)

      _ ->
        run_sykli(args)
    end
  end

  defp print_help do
    IO.puts("""
    sykli - CI pipelines in your language

    Usage: sykli [path]
           sykli run [path]
           sykli cache <command>

    Options:
      -h, --help       Show this help
      -v, --version    Show version

    Commands:
      sykli [path]     Run pipeline (default: current directory)
      sykli run [path] Run pipeline (explicit form)
      sykli delta      Run only tasks affected by git changes
      sykli graph      Show task graph (see: sykli graph --help)
      sykli cache      Manage cache (see: sykli cache --help)

    Examples:
      sykli                    Run pipeline in current directory
      sykli run                Same as above
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

        IO.puts(
          "\n#{IO.ANSI.green()}✓ All tasks completed in #{format_duration(duration)}#{IO.ANSI.reset()}"
        )

        # Results are {name, result, duration} tuples
        Enum.each(results, fn {name, _, _} ->
          IO.puts("  ✓ #{name}")
        end)

        halt(0)

      {:error, :no_sdk_file} ->
        IO.puts("#{IO.ANSI.red()}No sykli.go, sykli.rs, or sykli.exs found#{IO.ANSI.reset()}")
        halt(1)

      {:error, results} when is_list(results) ->
        IO.puts("\n#{IO.ANSI.red()}Build failed#{IO.ANSI.reset()}")
        halt(1)

      {:error, {:cycle_detected, path}} when is_list(path) and length(path) > 0 ->
        cycle_str = Enum.join(path, " -> ")

        IO.puts(
          "#{IO.ANSI.red()}Error: dependency cycle detected: #{cycle_str}#{IO.ANSI.reset()}"
        )

        halt(1)

      {:error, {:cycle_detected, _}} ->
        IO.puts("#{IO.ANSI.red()}Error: dependency cycle detected#{IO.ANSI.reset()}")
        halt(1)

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
        halt(1)
    end
  end

  # ----- DELTA SUBCOMMAND -----

  defp handle_delta(["--help"]) do
    IO.puts("""
    Usage: sykli delta [options] [path]

    Run only tasks affected by git changes.

    Analyzes git diff to find changed files, matches them against task inputs,
    and runs only affected tasks plus their dependents.

    Options:
      --from=<ref>    Compare against branch/commit (default: HEAD)
      --dry-run       Show affected tasks without running
      --json          Output as JSON (for tooling)
      --verbose       Show which files triggered each task
      --help          Show this help

    Examples:
      sykli delta                  Run affected tasks
      sykli delta --from=main      Compare against main branch
      sykli delta --dry-run        Show what would run
      sykli delta --dry-run -v     Show what would run and why
    """)
    halt(0)
  end

  defp handle_delta(args) do
    {opts, path} = parse_delta_args(args)
    path = path || "."
    from = Keyword.get(opts, :from, "HEAD")
    dry_run = Keyword.get(opts, :dry_run, false)
    json = Keyword.get(opts, :json, false)
    verbose = Keyword.get(opts, :verbose, false)

    # Get the task graph
    case get_task_graph(path) do
      {:ok, tasks} ->
        # Find affected tasks with details
        case Sykli.Delta.affected_tasks_detailed(tasks, from: from, path: path) do
          {:ok, []} ->
            if json do
              IO.puts(Jason.encode!(%{affected: [], changed_files: []}))
            else
              IO.puts("#{IO.ANSI.green()}No tasks affected by changes#{IO.ANSI.reset()}")
            end
            halt(0)

          {:ok, affected} ->
            affected_names = Enum.map(affected, & &1.name)

            if json do
              output_delta_json(affected, from, path)
              halt(0)
            end

            if dry_run do
              output_delta_dry_run(affected, verbose)
              halt(0)
            else
              # Run only affected tasks
              run_affected_tasks(path, affected_names)
            end

          {:error, reason} ->
            if json do
              IO.puts(Jason.encode!(%{error: Sykli.Delta.format_error(reason)}))
            else
              IO.puts("#{IO.ANSI.red()}#{Sykli.Delta.format_error(reason)}#{IO.ANSI.reset()}")
            end
            halt(1)
        end

      {:error, reason} ->
        if json do
          IO.puts(Jason.encode!(%{error: inspect(reason)}))
        else
          IO.puts("#{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
        end
        halt(1)
    end
  end

  defp output_delta_json(affected, from, path) do
    {:ok, changed_files} = Sykli.Delta.get_changed_files(from, path)

    output = %{
      affected: Enum.map(affected, fn a ->
        %{
          name: a.name,
          reason: a.reason,
          files: a.files,
          depends_on: a.depends_on
        }
      end),
      changed_files: changed_files,
      from: from
    }

    IO.puts(Jason.encode!(output, pretty: true))
  end

  defp output_delta_dry_run(affected, verbose) do
    IO.puts("#{IO.ANSI.cyan()}Affected tasks:#{IO.ANSI.reset()}")

    Enum.each(affected, fn task ->
      case task.reason do
        :direct ->
          if verbose and task.files != [] do
            files_str = Enum.take(task.files, 3) |> Enum.join(", ")
            suffix = if length(task.files) > 3, do: " +#{length(task.files) - 3} more", else: ""
            IO.puts("  #{IO.ANSI.green()}•#{IO.ANSI.reset()} #{task.name}")
            IO.puts("    #{IO.ANSI.faint()}↳ #{files_str}#{suffix}#{IO.ANSI.reset()}")
          else
            IO.puts("  #{IO.ANSI.green()}•#{IO.ANSI.reset()} #{task.name}")
          end

        :dependent ->
          if verbose do
            IO.puts("  #{IO.ANSI.yellow()}•#{IO.ANSI.reset()} #{task.name}")
            IO.puts("    #{IO.ANSI.faint()}↳ depends on: #{task.depends_on}#{IO.ANSI.reset()}")
          else
            IO.puts("  #{IO.ANSI.yellow()}•#{IO.ANSI.reset()} #{task.name} #{IO.ANSI.faint()}(via #{task.depends_on})#{IO.ANSI.reset()}")
          end
      end
    end)

    direct_count = Enum.count(affected, & &1.reason == :direct)
    dep_count = Enum.count(affected, & &1.reason == :dependent)

    IO.puts("")
    IO.puts("#{IO.ANSI.faint()}#{direct_count} direct, #{dep_count} dependent#{IO.ANSI.reset()}")
  end

  defp parse_delta_args(args) do
    {opts, rest} =
      Enum.reduce(args, {[], []}, fn arg, {opts, rest} ->
        cond do
          String.starts_with?(arg, "--from=") ->
            from = String.replace_prefix(arg, "--from=", "")
            {[{:from, from} | opts], rest}

          arg == "--dry-run" ->
            {[{:dry_run, true} | opts], rest}

          arg == "--json" ->
            {[{:json, true} | opts], rest}

          arg == "--verbose" or arg == "-v" ->
            {[{:verbose, true} | opts], rest}

          String.starts_with?(arg, "--") ->
            {opts, rest}

          true ->
            {opts, rest ++ [arg]}
        end
      end)

    {opts, List.first(rest)}
  end

  defp run_affected_tasks(path, affected_names) do
    affected_set = MapSet.new(affected_names)
    count = length(affected_names)

    IO.puts("#{IO.ANSI.cyan()}Running #{count} affected task(s)#{IO.ANSI.reset()}")
    Enum.each(affected_names, fn name ->
      IO.puts("  • #{name}")
    end)
    IO.puts("")

    # Use Sykli.run with a filter
    start_time = System.monotonic_time(:millisecond)

    case Sykli.run(path, filter: fn task -> MapSet.member?(affected_set, task.name) end) do
      {:ok, results} ->
        duration = System.monotonic_time(:millisecond) - start_time
        IO.puts("\n#{IO.ANSI.green()}✓ All affected tasks completed in #{format_duration(duration)}#{IO.ANSI.reset()}")

        Enum.each(results, fn {name, _, _} ->
          IO.puts("  ✓ #{name}")
        end)

        halt(0)

      {:error, _} ->
        IO.puts("\n#{IO.ANSI.red()}Build failed#{IO.ANSI.reset()}")
        halt(1)
    end
  end

  # ----- GRAPH SUBCOMMAND -----

  defp handle_graph(args) do
    {opts, rest} = Enum.split_with(args, &String.starts_with?(&1, "-"))

    if "--help" in opts or "-h" in opts do
      print_graph_help()
      halt(0)
    end

    {format, path} = parse_graph_args(opts, rest)

    case get_task_graph(path) do
      {:ok, tasks} ->
        output =
          case format do
            :mermaid -> Sykli.GraphViz.to_mermaid(tasks)
            :dot -> Sykli.GraphViz.to_dot(tasks)
          end

        IO.puts(output)
        halt(0)

      {:error, :no_sdk_file} ->
        IO.puts("#{IO.ANSI.red()}No sykli.go, sykli.rs, or sykli.exs found#{IO.ANSI.reset()}")
        halt(1)

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
        halt(1)
    end
  end

  defp parse_graph_args(opts, rest) do
    format = if "--dot" in opts, do: :dot, else: :mermaid
    path = List.first(rest) || "."
    {format, path}
  end

  defp print_graph_help do
    IO.puts("""
    Usage: sykli graph [options] [path]

    Show the task dependency graph in various formats.

    Options:
      --mermaid    Output as Mermaid diagram (default)
      --dot        Output as DOT (Graphviz) format
      -h, --help   Show this help

    Examples:
      sykli graph                  Show graph for current directory
      sykli graph ./my-project     Show graph for ./my-project
      sykli graph --dot            Output as DOT format
      sykli graph --dot | dot -Tpng -o graph.png
    """)
  end

  defp get_task_graph(path) do
    with {:ok, sdk} <- Sykli.Detector.find(path),
         {:ok, json} <- Sykli.Detector.emit(sdk),
         {:ok, data} <- Jason.decode(json) do
      tasks = parse_tasks_for_graph(data)
      {:ok, tasks}
    end
  end

  defp parse_tasks_for_graph(data) do
    (data["tasks"] || [])
    |> Enum.map(fn task ->
      %{
        name: task["name"],
        depends_on: task["depends_on"] || [],
        mounts: parse_mounts(task["mounts"]),
        inputs: task["inputs"]
      }
    end)
  end

  defp parse_mounts(nil), do: []
  defp parse_mounts(mounts) when is_list(mounts) do
    Enum.map(mounts, fn m ->
      %{
        resource: m["resource"],
        path: m["path"],
        type: m["type"]
      }
    end)
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

    IO.puts(
      "  clean --older-than <duration>  Delete cache older than <duration> (e.g., 7d, 24h, 30m)"
    )

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
    :erlang.halt(code, flush: true)
  end
end
