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

      ["watch" | watch_args] ->
        handle_watch(watch_args)

      ["report" | report_args] ->
        handle_report(report_args)

      ["history" | history_args] ->
        handle_history(history_args)

      ["daemon" | daemon_args] ->
        handle_daemon(daemon_args)

      ["init" | init_args] ->
        handle_init(init_args)

      ["validate" | validate_args] ->
        handle_validate(validate_args)

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

    Usage: sykli [options] [path]
           sykli run [options] [path]
           sykli daemon <command>
           sykli cache <command>

    Options:
      -h, --help                Show this help
      -v, --version             Show version
      --mesh                    Distribute tasks across connected BEAM nodes
      --filter=NAME             Only run tasks matching NAME
      --timeout=DURATION        Task timeout (default: 5m). Use 10m, 30s, or 0 for no timeout
      --target=TARGET           Execution target: local (default), k8s
      --allow-dirty             Allow running with uncommitted changes (K8s)
      --git-ssh-secret=NAME     K8s Secret for SSH git auth
      --git-token-secret=NAME   K8s Secret for HTTPS git auth

    Commands:
      sykli [path]     Run pipeline (default: current directory)
      sykli run [path] Run pipeline (explicit form)
      sykli init       Create a new sykli file (auto-detects language)
      sykli validate   Check sykli file for errors without running
      sykli delta      Run only tasks affected by git changes
      sykli watch      Watch files and re-run affected tasks
      sykli graph      Show task graph (see: sykli graph --help)
      sykli report     Show last run summary with task results
      sykli history    List recent runs
      sykli daemon     Manage daemon (see: sykli daemon --help)
      sykli cache      Manage cache (see: sykli cache --help)

    Examples:
      sykli                           Run pipeline in current directory
      sykli run                       Same as above
      sykli ./my-project              Run pipeline in ./my-project
      sykli --timeout=10m             Run with 10 minute timeout
      sykli --mesh                    Run with distributed mesh execution
      sykli --target=k8s              Run tasks as Kubernetes Jobs
      sykli --target=k8s --allow-dirty  Run K8s even with uncommitted changes
      sykli daemon start              Start mesh daemon
      sykli cache stats               Show cache statistics
    """)
  end

  defp run_sykli(args) do
    {path, opts} = parse_run_args(args)
    start_time = System.monotonic_time(:millisecond)

    # Build run options
    run_opts = []

    # Handle K8s target - prepare git context first
    case prepare_target_context(path, opts) do
      {:ok, target_opts} ->
        run_opts = target_opts ++ run_opts
        do_run_sykli(path, opts, run_opts, start_time)

      {:error, :dirty_workdir} ->
        IO.puts(
          "#{IO.ANSI.red()}Error: Uncommitted changes in working directory#{IO.ANSI.reset()}"
        )

        IO.puts("")
        IO.puts("K8s execution requires a clean git state to ensure reproducibility.")

        IO.puts(
          "Either commit your changes or use #{IO.ANSI.cyan()}--allow-dirty#{IO.ANSI.reset()} to proceed anyway."
        )

        halt(1)

      {:error, :not_a_git_repo} ->
        IO.puts("#{IO.ANSI.red()}Error: Not a git repository#{IO.ANSI.reset()}")
        IO.puts("")
        IO.puts("K8s execution requires git to clone source code into Jobs.")
        halt(1)

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
        halt(1)
    end
  end

  defp prepare_target_context(path, opts) do
    case opts[:target] do
      :k8s ->
        # Prepare git context for K8s
        git_opts = [
          allow_dirty: opts[:allow_dirty] || false,
          git_ssh_secret: opts[:git_ssh_secret],
          git_token_secret: opts[:git_token_secret]
        ]

        case Sykli.prepare_git_context_with_opts(path, git_opts) do
          {:ok, _ctx, pass_through} ->
            IO.puts("#{IO.ANSI.cyan()}Target: k8s#{IO.ANSI.reset()}")
            {:ok, [{:target, Sykli.Target.K8s} | pass_through]}

          error ->
            error
        end

      :local ->
        # Explicit local target
        {:ok, [{:target, Sykli.Target.Local}]}

      _ ->
        # Default local execution - no special setup needed
        {:ok, []}
    end
  end

  defp do_run_sykli(path, opts, run_opts, start_time) do
    # Select executor based on --mesh flag
    run_opts =
      if opts[:mesh] do
        IO.puts("#{IO.ANSI.cyan()}Running with mesh executor#{IO.ANSI.reset()}")
        [{:executor, Sykli.Executor.Mesh} | run_opts]
      else
        run_opts
      end

    # Add filter if specified
    run_opts =
      if opts[:filter] do
        filter_fn = fn task -> String.contains?(task.name, opts[:filter]) end
        [{:filter, filter_fn} | run_opts]
      else
        run_opts
      end

    case Sykli.run(path, run_opts) do
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

  @doc false
  def parse_run_args(args) do
    {opts, rest} =
      Enum.reduce(args, {[], []}, fn arg, {opts, rest} ->
        cond do
          arg == "--mesh" ->
            {[{:mesh, true} | opts], rest}

          String.starts_with?(arg, "--filter=") ->
            filter = String.replace_prefix(arg, "--filter=", "")
            {[{:filter, filter} | opts], rest}

          # K8s target flags
          String.starts_with?(arg, "--target=") ->
            target_str = String.replace_prefix(arg, "--target=", "")
            target = parse_target(target_str)
            {[{:target, target} | opts], rest}

          arg == "--allow-dirty" ->
            {[{:allow_dirty, true} | opts], rest}

          String.starts_with?(arg, "--git-ssh-secret=") ->
            secret = String.replace_prefix(arg, "--git-ssh-secret=", "")
            {[{:git_ssh_secret, secret} | opts], rest}

          String.starts_with?(arg, "--git-token-secret=") ->
            secret = String.replace_prefix(arg, "--git-token-secret=", "")
            {[{:git_token_secret, secret} | opts], rest}

          String.starts_with?(arg, "--timeout=") ->
            timeout_str = String.replace_prefix(arg, "--timeout=", "")
            timeout_ms = parse_timeout(timeout_str)
            {[{:timeout, timeout_ms} | opts], rest}

          String.starts_with?(arg, "--") ->
            IO.puts(
              :stderr,
              "#{IO.ANSI.yellow()}Warning: ignoring unknown option #{arg}#{IO.ANSI.reset()}"
            )

            {opts, rest}

          true ->
            {opts, rest ++ [arg]}
        end
      end)

    path = List.first(rest) || "."
    {path, opts}
  end

  defp parse_target("k8s"), do: :k8s
  defp parse_target("local"), do: :local
  defp parse_target(_), do: :local

  # Parse timeout string like "10m", "30s", "300", "0" (infinity)
  defp parse_timeout("0"), do: :infinity
  defp parse_timeout(str) do
    cond do
      String.ends_with?(str, "m") ->
        minutes = str |> String.trim_trailing("m") |> String.to_integer()
        minutes * 60 * 1000

      String.ends_with?(str, "s") ->
        seconds = str |> String.trim_trailing("s") |> String.to_integer()
        seconds * 1000

      true ->
        # Assume milliseconds if no unit
        String.to_integer(str)
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
      affected:
        Enum.map(affected, fn a ->
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
            IO.puts(
              "  #{IO.ANSI.yellow()}•#{IO.ANSI.reset()} #{task.name} #{IO.ANSI.faint()}(via #{task.depends_on})#{IO.ANSI.reset()}"
            )
          end
      end
    end)

    direct_count = Enum.count(affected, &(&1.reason == :direct))
    dep_count = Enum.count(affected, &(&1.reason == :dependent))

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

        IO.puts(
          "\n#{IO.ANSI.green()}✓ All affected tasks completed in #{format_duration(duration)}#{IO.ANSI.reset()}"
        )

        Enum.each(results, fn {name, _, _} ->
          IO.puts("  ✓ #{name}")
        end)

        halt(0)

      {:error, _} ->
        IO.puts("\n#{IO.ANSI.red()}Build failed#{IO.ANSI.reset()}")
        halt(1)
    end
  end

  # ----- WATCH SUBCOMMAND -----

  defp handle_watch(["--help"]) do
    IO.puts("""
    Usage: sykli watch [options] [path]

    Watch files and re-run affected tasks on changes.

    Options:
      --from=<ref>    Compare against branch/commit (default: HEAD)
      --help          Show this help

    Examples:
      sykli watch                  Watch current directory
      sykli watch ./my-project     Watch specific project
      sykli watch --from=main      Compare against main branch
    """)

    halt(0)
  end

  defp handle_watch(args) do
    {opts, path} = parse_watch_args(args)
    path = path || "."
    from = Keyword.get(opts, :from, "HEAD")

    case Sykli.Watch.start(path, from: from) do
      :ok ->
        halt(0)

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}Watch error: #{inspect(reason)}#{IO.ANSI.reset()}")
        halt(1)
    end
  end

  defp parse_watch_args(args) do
    {opts, rest} =
      Enum.reduce(args, {[], []}, fn arg, {opts, rest} ->
        cond do
          String.starts_with?(arg, "--from=") ->
            from = String.replace_prefix(arg, "--from=", "")
            {[{:from, from} | opts], rest}

          String.starts_with?(arg, "--") ->
            {opts, rest}

          true ->
            {opts, rest ++ [arg]}
        end
      end)

    {opts, List.first(rest)}
  end

  # ----- INIT SUBCOMMAND -----

  defp handle_init(["--help"]) do
    IO.puts("""
    Usage: sykli init [options] [path]

    Create a new sykli configuration file.

    Auto-detects project type from marker files:
      - go.mod     → sykli.go
      - Cargo.toml → sykli.rs
      - mix.exs    → sykli.exs

    Options:
      --go         Force Go (creates sykli.go)
      --rust       Force Rust (creates sykli.rs)
      --elixir     Force Elixir (creates sykli.exs)
      --force      Overwrite existing sykli file
      --help       Show this help

    Examples:
      sykli init              Auto-detect and create sykli file
      sykli init --go         Create sykli.go
      sykli init --rust       Create sykli.rs
      sykli init --force      Overwrite existing file
    """)

    halt(0)
  end

  defp handle_init(args) do
    {opts, path} = parse_init_args(args)
    path = path || "."
    language = Keyword.get(opts, :language)
    force = Keyword.get(opts, :force, false)

    init_opts = [force: force]
    init_opts = if language, do: [{:language, language} | init_opts], else: init_opts

    case Sykli.Init.init(path, init_opts) do
      {:ok, lang} ->
        file = sykli_filename(lang)
        IO.puts("#{IO.ANSI.green()}Created #{file}#{IO.ANSI.reset()}")
        IO.puts("")
        IO.puts("#{IO.ANSI.faint()}Next steps:#{IO.ANSI.reset()}")
        IO.puts("  1. Edit #{file} to customize your pipeline")
        IO.puts("  2. Run #{IO.ANSI.cyan()}sykli#{IO.ANSI.reset()} to execute")
        halt(0)

      {:error, :already_exists} ->
        IO.puts("#{IO.ANSI.yellow()}Sykli file already exists#{IO.ANSI.reset()}")
        IO.puts("#{IO.ANSI.faint()}Use --force to overwrite#{IO.ANSI.reset()}")
        halt(1)

      {:error, :unknown_project} ->
        IO.puts("#{IO.ANSI.red()}Could not detect project type#{IO.ANSI.reset()}")
        IO.puts("")
        IO.puts("No go.mod, Cargo.toml, or mix.exs found.")
        IO.puts("Use --go, --rust, or --elixir to specify language:")
        IO.puts("")
        IO.puts("  #{IO.ANSI.cyan()}sykli init --go#{IO.ANSI.reset()}")
        halt(1)
    end
  end

  defp parse_init_args(args) do
    {opts, rest} =
      Enum.reduce(args, {[], []}, fn arg, {opts, rest} ->
        cond do
          arg == "--go" ->
            {[{:language, :go} | opts], rest}

          arg == "--rust" ->
            {[{:language, :rust} | opts], rest}

          arg == "--elixir" ->
            {[{:language, :elixir} | opts], rest}

          arg == "--force" or arg == "-f" ->
            {[{:force, true} | opts], rest}

          String.starts_with?(arg, "--") ->
            {opts, rest}

          true ->
            {opts, rest ++ [arg]}
        end
      end)

    {opts, List.first(rest)}
  end

  defp sykli_filename(:go), do: "sykli.go"
  defp sykli_filename(:rust), do: "sykli.rs"
  defp sykli_filename(:elixir), do: "sykli.exs"

  # ----- VALIDATE SUBCOMMAND -----

  defp handle_validate(["--help"]) do
    IO.puts("""
    Usage: sykli validate [options] [path]

    Check sykli file for errors without running the pipeline.

    Validates:
      - No dependency cycles
      - All dependencies exist
      - No duplicate task names
      - No self-dependencies

    Options:
      --json       Output as JSON (for tooling)
      --help       Show this help

    Examples:
      sykli validate              Validate current directory
      sykli validate ./my-project Validate specific project
      sykli validate --json       Output validation result as JSON
    """)

    halt(0)
  end

  defp handle_validate(args) do
    {opts, path} = parse_validate_args(args)
    path = path || "."
    json_output = Keyword.get(opts, :json, false)

    case Sykli.Validate.validate(path) do
      {:ok, result} ->
        if json_output do
          IO.puts(Sykli.Validate.to_json(result))
        else
          output_validation_result(result)
        end

        if result.valid, do: halt(0), else: halt(1)

      {:error, :no_sdk_file} ->
        if json_output do
          IO.puts(Jason.encode!(%{valid: false, error: "No sykli file found"}))
        else
          IO.puts("#{IO.ANSI.red()}No sykli file found#{IO.ANSI.reset()}")
        end

        halt(1)

      {:error, reason} ->
        if json_output do
          IO.puts(Jason.encode!(%{valid: false, error: inspect(reason)}))
        else
          IO.puts("#{IO.ANSI.red()}Error: #{inspect(reason)}#{IO.ANSI.reset()}")
        end

        halt(1)
    end
  end

  defp parse_validate_args(args) do
    {opts, rest} =
      Enum.reduce(args, {[], []}, fn arg, {opts, rest} ->
        cond do
          arg == "--json" ->
            {[{:json, true} | opts], rest}

          String.starts_with?(arg, "--") ->
            {opts, rest}

          true ->
            {opts, rest ++ [arg]}
        end
      end)

    {opts, List.first(rest)}
  end

  defp output_validation_result(result) do
    if result.valid do
      IO.puts("#{IO.ANSI.green()}Valid#{IO.ANSI.reset()}")
      IO.puts("")
      IO.puts("#{IO.ANSI.faint()}Tasks: #{Enum.join(result.tasks, ", ")}#{IO.ANSI.reset()}")

      if result.warnings != [] do
        IO.puts("")

        Enum.each(result.warnings, fn {_type, msg} ->
          IO.puts("#{IO.ANSI.yellow()}Warning: #{msg}#{IO.ANSI.reset()}")
        end)
      end
    else
      IO.puts("#{IO.ANSI.red()}Invalid#{IO.ANSI.reset()}")
      IO.puts("")

      Enum.each(result.errors, fn error ->
        IO.puts("  #{IO.ANSI.red()}•#{IO.ANSI.reset()} #{error.message}")
      end)
    end
  end

  # ----- REPORT SUBCOMMAND -----

  defp handle_report(["--help"]) do
    IO.puts("""
    Usage: sykli report [options] [path]

    Show the last run summary with task results.

    Options:
      --last-good     Show last successful run instead
      --json          Output as JSON
      --help          Show this help

    Examples:
      sykli report              Show last run summary
      sykli report --last-good  Show last passing run
      sykli report --json       Output as JSON for tooling
    """)

    halt(0)
  end

  defp handle_report(args) do
    {opts, path} = parse_report_args(args)
    path = path || "."
    last_good = Keyword.get(opts, :last_good, false)
    json_output = Keyword.get(opts, :json, false)

    result =
      if last_good do
        Sykli.RunHistory.load_last_good(path: path)
      else
        Sykli.RunHistory.load_latest(path: path)
      end

    case result do
      {:ok, run} ->
        if json_output do
          output_report_json(run, path)
        else
          output_report(run, path)
        end

        halt(0)

      {:error, :no_runs} ->
        if json_output do
          IO.puts(Jason.encode!(%{error: "No runs found"}))
        else
          IO.puts("#{IO.ANSI.yellow()}No runs found#{IO.ANSI.reset()}")
          IO.puts("#{IO.ANSI.faint()}Run 'sykli' first to create a run record#{IO.ANSI.reset()}")
        end

        halt(1)

      {:error, :no_passing_runs} ->
        if json_output do
          IO.puts(Jason.encode!(%{error: "No passing runs found"}))
        else
          IO.puts("#{IO.ANSI.yellow()}No passing runs found#{IO.ANSI.reset()}")
        end

        halt(1)
    end
  end

  defp parse_report_args(args) do
    {opts, rest} =
      Enum.reduce(args, {[], []}, fn arg, {opts, rest} ->
        cond do
          arg == "--last-good" ->
            {[{:last_good, true} | opts], rest}

          arg == "--json" ->
            {[{:json, true} | opts], rest}

          String.starts_with?(arg, "--") ->
            {opts, rest}

          true ->
            {opts, rest ++ [arg]}
        end
      end)

    {opts, List.first(rest)}
  end

  defp output_report(run, path) do
    # Header box
    border_plain = "╭──────────────────────────────────────────────────╮"
    inner_width = String.length(border_plain) - 2

    IO.puts("#{IO.ANSI.cyan()}#{border_plain}#{IO.ANSI.reset()}")

    run_content = " Run: #{format_timestamp(run.timestamp)}"
    run_padding = max(0, inner_width - String.length(run_content))

    IO.puts(
      "#{IO.ANSI.cyan()}│#{IO.ANSI.reset()}#{run_content}#{String.duplicate(" ", run_padding)}#{IO.ANSI.cyan()}│#{IO.ANSI.reset()}"
    )

    commit_content = " Commit: #{run.git_ref} (#{run.git_branch})"
    commit_padding = max(0, inner_width - String.length(commit_content))

    IO.puts(
      "#{IO.ANSI.cyan()}│#{IO.ANSI.reset()}#{commit_content}#{String.duplicate(" ", commit_padding)}#{IO.ANSI.cyan()}│#{IO.ANSI.reset()}"
    )

    IO.puts(
      "#{IO.ANSI.cyan()}╰──────────────────────────────────────────────────╯#{IO.ANSI.reset()}"
    )

    IO.puts("")

    # Tasks
    Enum.each(run.tasks, fn task ->
      output_task_result(task, path)
    end)

    # Summary
    IO.puts("")

    case run.overall do
      :passed ->
        IO.puts("#{IO.ANSI.green()}All tasks passed#{IO.ANSI.reset()}")

      :failed ->
        IO.puts("#{IO.ANSI.red()}Run failed#{IO.ANSI.reset()}")

        # Show last good if available
        case Sykli.RunHistory.load_last_good(path: path) do
          {:ok, last_good} ->
            IO.puts(
              "#{IO.ANSI.faint()}Last good: #{format_timestamp(last_good.timestamp)} (#{last_good.git_ref})#{IO.ANSI.reset()}"
            )

          _ ->
            :ok
        end
    end
  end

  defp output_task_result(task, path) do
    status_icon =
      case task.status do
        :passed -> "#{IO.ANSI.green()}✓#{IO.ANSI.reset()}"
        :failed -> "#{IO.ANSI.red()}✗#{IO.ANSI.reset()}"
        :skipped -> "#{IO.ANSI.yellow()}○#{IO.ANSI.reset()}"
      end

    duration = format_duration(task.duration_ms)

    # Get streak for this task
    {:ok, streak} = Sykli.RunHistory.calculate_streak(task.name, path: path)

    streak_str =
      if task.status == :passed and streak > 1 do
        "#{IO.ANSI.faint()}(streak: #{streak})#{IO.ANSI.reset()}"
      else
        if task.status == :failed and streak == 0 do
          "#{IO.ANSI.faint()}(streak: 0)#{IO.ANSI.reset()}"
        else
          ""
        end
      end

    IO.puts(
      "  #{status_icon} #{task.name}  #{IO.ANSI.faint()}#{duration}#{IO.ANSI.reset()}  #{streak_str}"
    )

    # Show likely cause for failed tasks
    if task.status == :failed and task.likely_cause do
      Enum.each(task.likely_cause, fn file ->
        IO.puts("    #{IO.ANSI.faint()}└─ Likely cause: #{file}#{IO.ANSI.reset()}")
      end)
    end

    # Show error for failed tasks
    if task.status == :failed and task.error do
      IO.puts("    #{IO.ANSI.red()}└─ #{task.error}#{IO.ANSI.reset()}")
    end
  end

  defp output_report_json(run, _path) do
    output = %{
      id: run.id,
      timestamp: DateTime.to_iso8601(run.timestamp),
      git_ref: run.git_ref,
      git_branch: run.git_branch,
      overall: Atom.to_string(run.overall),
      tasks:
        Enum.map(run.tasks, fn t ->
          %{
            name: t.name,
            status: Atom.to_string(t.status),
            duration_ms: t.duration_ms,
            cached: t.cached,
            streak: t.streak
          }
          |> maybe_put(:error, t.error)
          |> maybe_put(:likely_cause, t.likely_cause)
        end)
    }

    IO.puts(Jason.encode!(output, pretty: true))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ----- HISTORY SUBCOMMAND -----

  defp handle_history(["--help"]) do
    IO.puts("""
    Usage: sykli history [options] [path]

    List recent runs.

    Options:
      --limit=N       Number of runs to show (default: 10)
      --json          Output as JSON
      --help          Show this help

    Examples:
      sykli history              List last 10 runs
      sykli history --limit=5    List last 5 runs
      sykli history --json       Output as JSON
    """)

    halt(0)
  end

  defp handle_history(args) do
    {opts, path} = parse_history_args(args)
    path = path || "."
    limit = Keyword.get(opts, :limit, 10)
    json_output = Keyword.get(opts, :json, false)

    case Sykli.RunHistory.list(path: path, limit: limit) do
      {:ok, []} ->
        if json_output do
          IO.puts(Jason.encode!(%{runs: []}))
        else
          IO.puts("#{IO.ANSI.yellow()}No runs found#{IO.ANSI.reset()}")
        end

        halt(0)

      {:ok, runs} ->
        if json_output do
          output_history_json(runs)
        else
          output_history(runs)
        end

        halt(0)
    end
  end

  defp parse_history_args(args) do
    {opts, rest} =
      Enum.reduce(args, {[], []}, fn arg, {opts, rest} ->
        cond do
          String.starts_with?(arg, "--limit=") ->
            limit_str = String.replace_prefix(arg, "--limit=", "")

            case Integer.parse(limit_str) do
              {limit, ""} -> {[{:limit, limit} | opts], rest}
              _ -> {opts, rest}
            end

          arg == "--json" ->
            {[{:json, true} | opts], rest}

          String.starts_with?(arg, "--") ->
            {opts, rest}

          true ->
            {opts, rest ++ [arg]}
        end
      end)

    {opts, List.first(rest)}
  end

  defp output_history(runs) do
    IO.puts("#{IO.ANSI.cyan()}Recent runs:#{IO.ANSI.reset()}")
    IO.puts("")

    Enum.each(runs, fn run ->
      status_icon =
        case run.overall do
          :passed -> "#{IO.ANSI.green()}✓#{IO.ANSI.reset()}"
          :failed -> "#{IO.ANSI.red()}✗#{IO.ANSI.reset()}"
        end

      passed = Enum.count(run.tasks, &(&1.status == :passed))
      failed = Enum.count(run.tasks, &(&1.status == :failed))
      total = length(run.tasks)

      summary =
        if failed > 0 do
          "#{IO.ANSI.red()}#{passed}/#{total}#{IO.ANSI.reset()}"
        else
          "#{IO.ANSI.green()}#{passed}/#{total}#{IO.ANSI.reset()}"
        end

      IO.puts(
        "  #{status_icon} #{format_timestamp(run.timestamp)}  #{run.git_ref |> String.slice(0, 7)}  #{summary}"
      )
    end)
  end

  defp output_history_json(runs) do
    output = %{
      runs:
        Enum.map(runs, fn run ->
          %{
            id: run.id,
            timestamp: DateTime.to_iso8601(run.timestamp),
            git_ref: run.git_ref,
            git_branch: run.git_branch,
            overall: Atom.to_string(run.overall),
            task_count: length(run.tasks),
            passed_count: Enum.count(run.tasks, &(&1.status == :passed)),
            failed_count: Enum.count(run.tasks, &(&1.status == :failed))
          }
        end)
    }

    IO.puts(Jason.encode!(output, pretty: true))
  end

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  # ----- DAEMON SUBCOMMAND -----

  defp handle_daemon(["--help"]) do
    print_daemon_help()
    halt(0)
  end

  defp handle_daemon(["-h"]) do
    print_daemon_help()
    halt(0)
  end

  defp handle_daemon(["start" | args]) do
    foreground = "--foreground" in args or "-f" in args

    role =
      case parse_role_arg(args) do
        {:ok, r} ->
          r

        {:error, invalid_role} ->
          IO.puts(:stderr, "Invalid daemon role: #{invalid_role}")
          IO.puts(:stderr, "Valid roles are: full, worker, coordinator")
          IO.puts(:stderr, "")
          print_daemon_help()
          halt(1)
      end

    # Parse and set labels if provided
    case parse_labels_arg(args) do
      {:ok, labels} when labels != nil ->
        System.put_env("SYKLI_LABELS", labels)
      _ ->
        :ok
    end

    role_label =
      case role do
        :full -> ""
        :worker -> " (worker mode)"
        :coordinator -> " (coordinator mode)"
      end

    IO.puts("#{IO.ANSI.cyan()}Starting SYKLI daemon#{role_label}...#{IO.ANSI.reset()}")

    case Sykli.Daemon.start(foreground: foreground, role: role) do
      {:ok, _pid} ->
        if foreground do
          IO.puts("#{IO.ANSI.green()}Daemon running in foreground#{IO.ANSI.reset()}")
          IO.puts("#{IO.ANSI.faint()}Press Ctrl+C to stop#{IO.ANSI.reset()}")

          # Trap exit signals to ensure cleanup
          Process.flag(:trap_exit, true)

          # Keep the process alive until interrupted
          receive do
            :stop -> :ok
            {:EXIT, _pid, _reason} -> :ok
          after
            :infinity -> :ok
          end

          # Cleanup on exit
          Sykli.Daemon.remove_pid_file()
        else
          IO.puts("#{IO.ANSI.green()}Daemon started#{IO.ANSI.reset()}")
          print_daemon_status()
          halt(0)
        end

      {:error, :already_running} ->
        IO.puts("#{IO.ANSI.yellow()}Daemon is already running#{IO.ANSI.reset()}")
        print_daemon_status()
        halt(0)

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}Failed to start daemon: #{inspect(reason)}#{IO.ANSI.reset()}")
        halt(1)
    end
  end

  defp handle_daemon(["stop"]) do
    IO.puts("#{IO.ANSI.cyan()}Stopping SYKLI daemon...#{IO.ANSI.reset()}")

    case Sykli.Daemon.stop() do
      :ok ->
        IO.puts("#{IO.ANSI.green()}Daemon stopped#{IO.ANSI.reset()}")
        halt(0)

      {:error, :not_running} ->
        IO.puts("#{IO.ANSI.yellow()}Daemon is not running#{IO.ANSI.reset()}")
        halt(0)

      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}Failed to stop daemon: #{inspect(reason)}#{IO.ANSI.reset()}")
        halt(1)
    end
  end

  defp handle_daemon(["status"]) do
    print_daemon_status()
    halt(0)
  end

  defp handle_daemon(_) do
    print_daemon_help()
    halt(1)
  end

  defp parse_role_arg(args) do
    role_arg =
      Enum.find_value(args, fn arg ->
        cond do
          String.starts_with?(arg, "--role=") ->
            String.replace_prefix(arg, "--role=", "")

          true ->
            nil
        end
      end)

    # Also check for --role <value> format
    role_arg =
      role_arg ||
        case Enum.find_index(args, &(&1 == "--role")) do
          nil -> nil
          idx -> Enum.at(args, idx + 1)
        end

    case role_arg do
      nil -> {:ok, :full}
      "worker" -> {:ok, :worker}
      "coordinator" -> {:ok, :coordinator}
      "full" -> {:ok, :full}
      invalid -> {:error, invalid}
    end
  end

  defp parse_labels_arg(args) do
    labels_arg =
      Enum.find_value(args, fn arg ->
        cond do
          String.starts_with?(arg, "--labels=") ->
            String.replace_prefix(arg, "--labels=", "")

          String.starts_with?(arg, "-l=") ->
            String.replace_prefix(arg, "-l=", "")

          true ->
            nil
        end
      end)

    # Also check for --labels <value> format
    labels_arg =
      labels_arg ||
        case Enum.find_index(args, &(&1 in ["--labels", "-l"])) do
          nil -> nil
          idx -> Enum.at(args, idx + 1)
        end

    {:ok, labels_arg}
  end

  defp print_daemon_help do
    IO.puts("""
    Usage: sykli daemon <command>

    Manage the SYKLI mesh daemon.

    The daemon keeps a BEAM node running that:
    - Auto-discovers other SYKLI daemons on the network
    - Receives and executes tasks from other nodes
    - Reports status to the coordinator

    Roles:
      --role full         Can execute tasks AND coordinate (default)
      --role worker       Can only execute tasks
      --role coordinator  Can only coordinate (run dashboard, aggregate events)

    Labels:
      --labels=<list>     Comma-separated node labels for task placement
                          Also settable via SYKLI_LABELS env var

    Commands:
      start              Start the daemon (backgrounds by default)
      start --foreground Start in foreground (for debugging)
      start --role <role> Start with specific role
      start --labels=<l>  Start with node labels
      stop               Stop the daemon
      status             Show daemon status

    Examples:
      sykli daemon start                  Start full daemon (default)
      sykli daemon start --role worker    Start worker-only daemon
      sykli daemon start --labels=docker,gpu  Start with labels
      sykli daemon start -f               Start in foreground
      sykli daemon status                 Check if daemon is running
      sykli daemon stop                   Stop the daemon

    Labels help with task placement. Tasks can require labels:
      .requires("gpu")  → only runs on nodes with "gpu" label
    """)
  end

  defp print_daemon_status do
    case Sykli.Daemon.status() do
      {:running, info} ->
        IO.puts("")
        IO.puts("#{IO.ANSI.green()}● Daemon is running#{IO.ANSI.reset()}")
        IO.puts("  PID:      #{info.pid}")
        IO.puts("  PID file: #{info.pid_file}")

        if info.node do
          role = Sykli.Daemon.node_role(info.node)
          IO.puts("  Node:     #{info.node}")
          IO.puts("  Role:     #{format_role(role)}")
        end

        # Show connected nodes - safely handle if cluster is not running
        nodes = get_cluster_nodes_safely()

        if length(nodes) > 0 do
          IO.puts("  Mesh:     #{length(nodes)} node(s) connected")

          Enum.each(nodes, fn n ->
            role = Sykli.Daemon.node_role(n)
            role_badge = format_role_badge(role)
            IO.puts("            • #{n} #{role_badge}")
          end)
        else
          IO.puts("  Mesh:     #{IO.ANSI.faint()}no other nodes#{IO.ANSI.reset()}")
        end

      {:stopped, info} ->
        IO.puts("")
        IO.puts("#{IO.ANSI.faint()}○ Daemon is not running#{IO.ANSI.reset()}")

        case info.reason do
          :process_dead ->
            IO.puts(
              "  #{IO.ANSI.yellow()}Stale PID file found (process #{info.stale_pid} is dead)#{IO.ANSI.reset()}"
            )

            IO.puts("  Run 'sykli daemon start' to start a new daemon")

          _ ->
            IO.puts("  Run 'sykli daemon start' to start")
        end
    end
  end

  defp format_role(:full), do: "full (execute + coordinate)"
  defp format_role(:worker), do: "worker (execute only)"
  defp format_role(:coordinator), do: "coordinator (coordinate only)"

  defp format_role_badge(:full), do: ""
  defp format_role_badge(:worker), do: "#{IO.ANSI.cyan()}[worker]#{IO.ANSI.reset()}"
  defp format_role_badge(:coordinator), do: "#{IO.ANSI.magenta()}[coordinator]#{IO.ANSI.reset()}"

  defp get_cluster_nodes_safely do
    if Node.alive?() do
      try do
        Sykli.Cluster.nodes()
      rescue
        _ -> []
      end
    else
      []
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
    IO.puts("  Location:    #{Sykli.Cache.get_cache_dir()}")
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
    IO.puts(Sykli.Cache.get_cache_dir())
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
