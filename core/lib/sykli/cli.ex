defmodule Sykli.CLI do
  @moduledoc """
  CLI entry point for escript.
  """

  alias Sykli.Error
  alias Sykli.Error.Formatter

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

      ["verify" | verify_args] ->
        handle_verify(verify_args)

      ["explain" | explain_args] ->
        handle_explain(explain_args)

      ["context" | context_args] ->
        handle_context(context_args)

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
      --timeout=DURATION        Per-task timeout (default: 5m). Use 10m, 30s, 2h, 1d, or 0 for no timeout
      --target=TARGET           Execution target: local (default), k8s
      --allow-dirty             Allow running with uncommitted changes (K8s)
      --git-ssh-secret=NAME     K8s Secret for SSH git auth
      --git-token-secret=NAME   K8s Secret for HTTPS git auth

    Commands:
      sykli [path]     Run pipeline (default: current directory)
      sykli run [path] Run pipeline (explicit form)
      sykli init       Create a new sykli file (auto-detects language)
      sykli validate   Check sykli file for errors without running
      sykli explain    Show last run occurrence (AI-readable report)
      sykli context    Generate AI context file (.sykli/context.json)
      sykli verify     Cross-platform verification via mesh nodes
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

      {:error, reason} ->
        display_error(reason)
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

    # Add timeout if specified
    run_opts =
      if opts[:timeout] do
        [{:timeout, opts[:timeout]} | run_opts]
      else
        run_opts
      end

    case Sykli.run(path, run_opts) do
      {:ok, results} ->
        duration = System.monotonic_time(:millisecond) - start_time

        IO.puts(
          "\n#{IO.ANSI.green()}✓ All tasks completed in #{format_duration(duration)}#{IO.ANSI.reset()}"
        )

        # Results are TaskResult structs
        Enum.each(results, fn %Sykli.Executor.TaskResult{name: name} ->
          IO.puts("  ✓ #{name}")
        end)

        halt(0)

      {:error, results} when is_list(results) ->
        # Task failures are already displayed during execution
        IO.puts("\n#{IO.ANSI.red()}Build failed#{IO.ANSI.reset()}")

        IO.puts(
          "\n  #{IO.ANSI.faint()}💡 Ask your AI: \"read .sykli/occurrence.json and fix the failure\"#{IO.ANSI.reset()}"
        )

        halt(1)

      {:error, reason} ->
        display_error(reason)
        halt(1)
    end
  end

  @doc false
  def parse_run_args(args) do
    {opts, rest} = do_parse_run_args(args, [], [])
    path = List.first(rest) || "."
    {path, opts}
  end

  defp do_parse_run_args([], opts, rest), do: {opts, rest}

  defp do_parse_run_args(["--mesh" | tail], opts, rest),
    do: do_parse_run_args(tail, [{:mesh, true} | opts], rest)

  defp do_parse_run_args(["--allow-dirty" | tail], opts, rest),
    do: do_parse_run_args(tail, [{:allow_dirty, true} | opts], rest)

  defp do_parse_run_args(["--filter=" <> filter | tail], opts, rest),
    do: do_parse_run_args(tail, [{:filter, filter} | opts], rest)

  defp do_parse_run_args(["--target=" <> target_str | tail], opts, rest),
    do: do_parse_run_args(tail, [{:target, parse_target(target_str)} | opts], rest)

  defp do_parse_run_args(["--git-ssh-secret=" <> secret | tail], opts, rest),
    do: do_parse_run_args(tail, [{:git_ssh_secret, secret} | opts], rest)

  defp do_parse_run_args(["--git-token-secret=" <> secret | tail], opts, rest),
    do: do_parse_run_args(tail, [{:git_token_secret, secret} | opts], rest)

  defp do_parse_run_args(["--timeout=" <> timeout_str | tail], opts, rest),
    do: do_parse_run_args(tail, [{:timeout, parse_timeout(timeout_str)} | opts], rest)

  # --timeout VALUE (space-separated)
  defp do_parse_run_args(["--timeout", value | tail], opts, rest)
       when is_binary(value) and binary_part(value, 0, 1) != "-",
       do: do_parse_run_args(tail, [{:timeout, parse_timeout(value)} | opts], rest)

  # --filter VALUE (space-separated)
  defp do_parse_run_args(["--filter", value | tail], opts, rest)
       when is_binary(value) and binary_part(value, 0, 1) != "-",
       do: do_parse_run_args(tail, [{:filter, value} | opts], rest)

  # --target VALUE (space-separated)
  defp do_parse_run_args(["--target", value | tail], opts, rest)
       when is_binary(value) and binary_part(value, 0, 1) != "-",
       do: do_parse_run_args(tail, [{:target, parse_target(value)} | opts], rest)

  defp do_parse_run_args(["--" <> _ = arg | tail], opts, rest) do
    IO.puts(
      :stderr,
      "#{IO.ANSI.yellow()}Warning: ignoring unknown option #{arg}#{IO.ANSI.reset()}"
    )

    do_parse_run_args(tail, opts, rest)
  end

  defp do_parse_run_args([arg | tail], opts, rest),
    do: do_parse_run_args(tail, opts, rest ++ [arg])

  defp parse_target("k8s"), do: :k8s
  defp parse_target("local"), do: :local
  defp parse_target(_), do: :local

  # Parse timeout string like "10m", "30s", "2h", "1d", "300", "0" (infinity)
  defp parse_timeout("0"), do: :infinity

  defp parse_timeout(str) do
    result =
      cond do
        String.ends_with?(str, "d") ->
          parse_timeout_unit(str, "d", 24 * 60 * 60 * 1000)

        String.ends_with?(str, "h") ->
          parse_timeout_unit(str, "h", 60 * 60 * 1000)

        String.ends_with?(str, "m") ->
          parse_timeout_unit(str, "m", 60 * 1000)

        String.ends_with?(str, "s") ->
          parse_timeout_unit(str, "s", 1000)

        true ->
          # Assume milliseconds if no unit
          case Integer.parse(str) do
            {ms, ""} -> {:ok, ms}
            _ -> {:error, str}
          end
      end

    case result do
      {:ok, ms} when ms >= 0 -> ms
      {:ok, _ms} -> invalid_timeout!(str)
      {:error, _} -> invalid_timeout!(str)
    end
  end

  defp parse_timeout_unit(str, suffix, multiplier) do
    value = String.trim_trailing(str, suffix)

    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n * multiplier}
      {_n, ""} -> {:error, str}
      _ -> {:error, str}
    end
  end

  defp invalid_timeout!(value) do
    IO.puts(:stderr, """
    #{IO.ANSI.red()}Invalid timeout value: #{value}#{IO.ANSI.reset()}

    Expected formats:
      --timeout=0       (no timeout / infinity)
      --timeout=300     (milliseconds)
      --timeout=10s     (seconds)
      --timeout=5m      (minutes)
      --timeout=2h      (hours)
      --timeout=1d      (days)
    """)

    halt(1)
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
          error = Error.wrap(reason)
          IO.puts(Jason.encode!(%{error: error.message, code: error.code}))
        else
          display_error(reason)
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

        Enum.each(results, fn %Sykli.Executor.TaskResult{name: name} ->
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
        display_error(reason)
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

      {:error, reason} ->
        error = Error.wrap(reason)

        if json_output do
          IO.puts(Jason.encode!(%{valid: false, error: error.message, code: error.code}))
        else
          display_error(error)
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

  # ----- VERIFY SUBCOMMAND -----

  defp handle_verify(["--help"]) do
    IO.puts("""
    Usage: sykli verify [options]

    Cross-platform verification via mesh nodes.

    Loads the last run manifest, discovers remote BEAM nodes, and re-runs
    platform-sensitive tasks on nodes with different OS/architecture.

    Options:
      --from=<id>     Run to verify: "latest" (default) or a run ID
      --dry-run       Show verification plan without executing
      --json          Output as JSON (for tooling)
      --help          Show this help

    Task-level control (in SDK):
      .Verify("cross_platform")   Verify on different OS/arch (default behavior)
      .Verify("always")           Always verify on any remote node
      .Verify("never")            Never verify this task

    Examples:
      sykli verify                  Verify latest run on mesh
      sykli verify --dry-run        Show what would be verified
      sykli verify --dry-run --json JSON verification plan
      sykli verify --from=abc123    Verify a specific run
    """)

    halt(0)
  end

  defp handle_verify(args) do
    {opts, _rest} = parse_verify_args(args)
    from = Keyword.get(opts, :from, "latest")
    dry_run = Keyword.get(opts, :dry_run, false)
    json_output = Keyword.get(opts, :json, false)

    verify_opts = [from: from]

    if dry_run do
      case Sykli.Verify.plan(verify_opts) do
        {:ok, plan} ->
          if json_output do
            output_verify_plan_json(plan)
          else
            output_verify_plan(plan)
          end

          halt(0)

        {:error, :no_runs} ->
          if json_output do
            IO.puts(Jason.encode!(%{error: "No runs found"}))
          else
            IO.puts("#{IO.ANSI.red()}No runs found#{IO.ANSI.reset()}")

            IO.puts(
              "#{IO.ANSI.faint()}Run 'sykli' first to create a run record#{IO.ANSI.reset()}"
            )
          end

          halt(1)

        {:error, {:run_not_found, run_id}} ->
          if json_output do
            IO.puts(Jason.encode!(%{error: "Run not found: #{run_id}"}))
          else
            IO.puts("#{IO.ANSI.red()}Run not found: #{run_id}#{IO.ANSI.reset()}")
          end

          halt(1)

        {:error, reason} ->
          if json_output do
            IO.puts(Jason.encode!(%{error: inspect(reason)}))
          else
            display_error(reason)
          end

          halt(1)
      end
    else
      case Sykli.Verify.verify(verify_opts) do
        {:ok, plan} ->
          if json_output do
            output_verify_plan_json(plan)
          else
            output_verify_result(plan)
          end

          halt(0)

        {:error, :no_runs} ->
          if json_output do
            IO.puts(Jason.encode!(%{error: "No runs found"}))
          else
            IO.puts("#{IO.ANSI.red()}No runs found#{IO.ANSI.reset()}")

            IO.puts(
              "#{IO.ANSI.faint()}Run 'sykli' first to create a run record#{IO.ANSI.reset()}"
            )
          end

          halt(1)

        {:error, {:run_not_found, run_id}} ->
          if json_output do
            IO.puts(Jason.encode!(%{error: "Run not found: #{run_id}"}))
          else
            IO.puts("#{IO.ANSI.red()}Run not found: #{run_id}#{IO.ANSI.reset()}")
          end

          halt(1)

        {:error, reason} ->
          if json_output do
            IO.puts(Jason.encode!(%{error: inspect(reason)}))
          else
            display_error(reason)
          end

          halt(1)
      end
    end
  end

  defp parse_verify_args(args) do
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

          String.starts_with?(arg, "--") ->
            {opts, rest}

          true ->
            {opts, rest ++ [arg]}
        end
      end)

    {opts, List.first(rest)}
  end

  defp output_verify_plan(plan) do
    if plan.entries == [] do
      IO.puts("#{IO.ANSI.green()}No tasks need verification#{IO.ANSI.reset()}")

      if plan.skipped != [] do
        IO.puts("")
        IO.puts("#{IO.ANSI.faint()}Skipped #{length(plan.skipped)} task(s):#{IO.ANSI.reset()}")

        Enum.each(plan.skipped, fn {name, reason} ->
          IO.puts(
            "  #{IO.ANSI.faint()}○#{IO.ANSI.reset()} #{name} #{IO.ANSI.faint()}(#{format_skip_reason(reason)})#{IO.ANSI.reset()}"
          )
        end)
      end
    else
      IO.puts("#{IO.ANSI.cyan()}Verification plan:#{IO.ANSI.reset()}")
      IO.puts("")

      Enum.each(plan.entries, fn entry ->
        reason_str = format_verify_reason(entry.reason)

        labels_str =
          if entry.target_labels, do: " [#{Enum.join(entry.target_labels, ", ")}]", else: ""

        IO.puts(
          "  #{IO.ANSI.green()}•#{IO.ANSI.reset()} #{entry.task_name} → #{entry.target_node}#{labels_str}"
        )

        IO.puts("    #{IO.ANSI.faint()}#{reason_str}#{IO.ANSI.reset()}")
      end)

      if plan.skipped != [] do
        IO.puts("")
        IO.puts("#{IO.ANSI.faint()}Skipped #{length(plan.skipped)} task(s)#{IO.ANSI.reset()}")
      end

      IO.puts("")

      IO.puts(
        "#{IO.ANSI.faint()}#{length(plan.entries)} to verify, #{length(plan.skipped)} skipped#{IO.ANSI.reset()}"
      )
    end
  end

  defp output_verify_result(plan) do
    IO.puts("#{IO.ANSI.green()}✓ Verification complete#{IO.ANSI.reset()}")
    IO.puts("")

    Enum.each(plan.entries, fn entry ->
      IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{entry.task_name} → #{entry.target_node}")
    end)

    IO.puts("")

    IO.puts(
      "#{IO.ANSI.faint()}#{length(plan.entries)} verified, #{length(plan.skipped)} skipped#{IO.ANSI.reset()}"
    )
  end

  defp output_verify_plan_json(plan) do
    output = %{
      entries:
        Enum.map(plan.entries, fn entry ->
          %{
            task_name: entry.task_name,
            target_node: to_string(entry.target_node),
            target_labels: entry.target_labels,
            reason: Atom.to_string(entry.reason)
          }
        end),
      skipped:
        Enum.map(plan.skipped, fn {name, reason} ->
          %{task_name: name, reason: Atom.to_string(reason)}
        end),
      local_labels: plan.local_labels,
      remote_nodes:
        Enum.map(plan.remote_nodes, fn n ->
          %{node: to_string(n.node), labels: n.labels}
        end)
    }

    IO.puts(Jason.encode!(output, pretty: true))
  end

  defp format_skip_reason(:cached), do: "cached"
  defp format_skip_reason(:skipped), do: "skipped in run"
  defp format_skip_reason(:verify_never), do: "verify: never"
  defp format_skip_reason(:no_remote_nodes), do: "no remote nodes"
  defp format_skip_reason(:same_platform), do: "same platform"
  defp format_skip_reason(:task_not_found), do: "task not in graph"
  defp format_skip_reason(reason), do: to_string(reason)

  defp format_verify_reason(:cross_platform), do: "cross-platform verification"
  defp format_verify_reason(:retry_on_different_platform), do: "retry on different platform"
  defp format_verify_reason(:explicit_verify), do: "explicit verify: always"
  defp format_verify_reason(reason), do: to_string(reason)

  # ----- EXPLAIN SUBCOMMAND -----

  defp handle_explain(["--help"]) do
    IO.puts("""
    Usage: sykli explain [options] [path]

    Show the last run occurrence — an AI-readable report of what happened.

    The occurrence file (.sykli/occurrence.json) contains structured errors,
    git context, causality analysis, and per-task history in a single file.

    Options:
      --json       Output raw JSON (default: human-readable summary)
      --help       Show this help

    Examples:
      sykli explain              Show human-readable summary
      sykli explain --json       Output raw occurrence JSON
    """)

    halt(0)
  end

  defp handle_explain(args) do
    {opts, path} = parse_explain_args(args)
    path = path || "."
    json_output = Keyword.get(opts, :json, false)

    # Try hot path (ETS store) first, fall back to cold path (JSON file)
    data = load_occurrence_hot(path)

    case data do
      nil ->
        IO.puts("#{IO.ANSI.yellow()}No occurrence data found#{IO.ANSI.reset()}")

        IO.puts(
          "#{IO.ANSI.faint()}Run 'sykli' first to generate occurrence data#{IO.ANSI.reset()}"
        )

        halt(1)

      occurrence ->
        if json_output do
          IO.puts(Jason.encode!(occurrence, pretty: true))
        else
          output_explain_summary(occurrence)
        end

        halt(0)
    end
  end

  defp load_occurrence_hot(path) do
    # Hot path: try ETS store (instant, if daemon is running)
    case safe_store_call(fn -> Sykli.Occurrence.Store.get_latest() end) do
      nil ->
        # Cold path: read JSON file
        load_occurrence_cold(path)

      occurrence ->
        occurrence
    end
  end

  defp load_occurrence_cold(path) do
    occurrence_path = Path.join([path, ".sykli", "occurrence.json"])

    case File.read(occurrence_path) do
      {:ok, json} -> Jason.decode!(json)
      {:error, _} -> nil
    end
  end

  defp safe_store_call(fun) do
    fun.()
  catch
    :exit, _ -> nil
    :error, _ -> nil
  end

  defp parse_explain_args(args) do
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

  defp output_explain_summary(data) do
    ci_data = data["ci_data"] || %{}
    summary = ci_data["summary"] || %{}
    git = ci_data["git"] || %{}
    tasks = ci_data["tasks"] || []
    error_block = data["error"]
    reasoning = data["reasoning"]

    # Header
    outcome = data["outcome"] || "unknown"
    outcome_color = if outcome == "passed", do: IO.ANSI.green(), else: IO.ANSI.red()
    outcome_icon = if outcome == "passed", do: "\u2713", else: "\u2717"

    IO.puts("")

    IO.puts(
      "#{outcome_color}#{outcome_icon} Run #{outcome}#{IO.ANSI.reset()} #{IO.ANSI.faint()}#{data["id"]}#{IO.ANSI.reset()}"
    )

    if git["sha"] do
      IO.puts(
        "  #{IO.ANSI.faint()}#{git["sha"]} (#{git["branch"] || "detached"})#{IO.ANSI.reset()}"
      )
    end

    duration_str = format_duration(data["history"]["duration_ms"] || 0)

    IO.puts(
      "  #{IO.ANSI.faint()}#{summary["passed"] || 0} passed, #{summary["failed"] || 0} failed, #{summary["cached"] || 0} cached in #{duration_str}#{IO.ANSI.reset()}"
    )

    # Error block (FALSE Protocol)
    if error_block do
      IO.puts("")
      IO.puts("#{IO.ANSI.red()}Error: #{error_block["what_failed"]}#{IO.ANSI.reset()}")

      if error_block["suggested_fix"] do
        IO.puts("  #{IO.ANSI.cyan()}Fix: #{error_block["suggested_fix"]}#{IO.ANSI.reset()}")
      end

      causes = error_block["possible_causes"] || []

      Enum.each(Enum.take(causes, 3), fn cause ->
        IO.puts("  #{IO.ANSI.faint()}\u2514\u2500 #{cause}#{IO.ANSI.reset()}")
      end)
    end

    IO.puts("")

    # Tasks
    Enum.each(tasks, fn task ->
      status = task["status"]

      icon =
        case status do
          "passed" -> "#{IO.ANSI.green()}\u2713#{IO.ANSI.reset()}"
          "cached" -> "#{IO.ANSI.yellow()}\u2299#{IO.ANSI.reset()}"
          "failed" -> "#{IO.ANSI.red()}\u2717#{IO.ANSI.reset()}"
          "skipped" -> "#{IO.ANSI.faint()}\u25CB#{IO.ANSI.reset()}"
          "blocked" -> "#{IO.ANSI.faint()}\u25CB#{IO.ANSI.reset()}"
          _ -> " "
        end

      dur = format_duration(task["duration_ms"] || 0)
      IO.puts("  #{icon} #{task["name"]}  #{IO.ANSI.faint()}#{dur}#{IO.ANSI.reset()}")

      # Show error for failed tasks
      if status == "failed" do
        case task["error"] do
          %{"message" => msg} ->
            IO.puts("    #{IO.ANSI.red()}\u2514\u2500 #{msg}#{IO.ANSI.reset()}")

          %{"code" => code} ->
            IO.puts("    #{IO.ANSI.red()}\u2514\u2500 [#{code}]#{IO.ANSI.reset()}")

          _ ->
            :ok
        end

        # Show hints
        hints = get_in(task, ["error", "hints"]) || []

        Enum.each(hints, fn hint ->
          IO.puts("    #{IO.ANSI.cyan()}   hint: #{hint}#{IO.ANSI.reset()}")
        end)
      end

      # Show history if interesting
      case task["history"] do
        %{"flaky" => true} ->
          IO.puts("    #{IO.ANSI.yellow()}   \u26A0 flaky#{IO.ANSI.reset()}")

        _ ->
          :ok
      end
    end)

    # Reasoning section (FALSE Protocol)
    if reasoning do
      IO.puts("")
      IO.puts("#{IO.ANSI.cyan()}Reasoning:#{IO.ANSI.reset()} #{reasoning["summary"]}")

      per_task = reasoning["tasks"] || %{}

      Enum.each(per_task, fn {task_name, detail} ->
        files = detail["changed_files"] || []

        if files != [] do
          IO.puts("  #{task_name}:")

          Enum.each(Enum.take(files, 5), fn file ->
            IO.puts("    #{IO.ANSI.faint()}\u2514\u2500 #{file}#{IO.ANSI.reset()}")
          end)

          if length(files) > 5 do
            IO.puts(
              "    #{IO.ANSI.faint()}\u2514\u2500 +#{length(files) - 5} more#{IO.ANSI.reset()}"
            )
          end
        end
      end)
    end

    IO.puts("")
  end

  # ----- CONTEXT SUBCOMMAND -----

  defp handle_context(["--help"]) do
    IO.puts("""
    Usage: sykli context [options] [path]

    Generate AI context file (.sykli/context.json).

    This file provides structured information about your pipeline for AI assistants,
    including task metadata, coverage mapping, and last run results.

    Options:
      --help       Show this help

    Examples:
      sykli context              Generate context for current directory
      sykli context ./my-project Generate context for specific project
    """)

    halt(0)
  end

  defp handle_context(args) do
    path = List.first(args) || "."

    case generate_context_file(path) do
      :ok ->
        IO.puts("#{IO.ANSI.green()}✓#{IO.ANSI.reset()} Generated .sykli/context.json")
        halt(0)

      {:error, reason} ->
        IO.puts(
          "#{IO.ANSI.red()}✗#{IO.ANSI.reset()} Failed to generate context: #{inspect(reason)}"
        )

        halt(1)
    end
  end

  defp generate_context_file(path) do
    alias Sykli.{Detector, Graph, Context, RunHistory}

    with {:ok, sdk_file} <- Detector.find(path),
         {:ok, json} <- Detector.emit(sdk_file),
         {:ok, graph} <- Graph.parse(json) do
      # Try to load last run for context
      run_result =
        case RunHistory.load_latest(path: path) do
          {:ok, run} ->
            %{
              timestamp: run.timestamp,
              outcome: if(run.overall == :passed, do: :success, else: :failure),
              duration_ms: Enum.reduce(run.tasks, 0, fn t, acc -> acc + (t.duration_ms || 0) end),
              tasks:
                Enum.map(run.tasks, fn t ->
                  %{
                    name: t.name,
                    status: t.status,
                    duration_ms: t.duration_ms,
                    cached: t.cached,
                    error: t.error
                  }
                end)
            }

          {:error, _} ->
            nil
        end

      # Expand matrix and generate context
      expanded_graph = Graph.expand_matrix(graph)
      Context.generate(expanded_graph, run_result, path)
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

  defp output_task_result(task, _path) do
    status_icon =
      case task.status do
        :passed -> "#{IO.ANSI.green()}✓#{IO.ANSI.reset()}"
        :failed -> "#{IO.ANSI.red()}✗#{IO.ANSI.reset()}"
        :skipped -> "#{IO.ANSI.yellow()}○#{IO.ANSI.reset()}"
      end

    duration = format_duration(task.duration_ms)

    # Use stored streak from run
    streak_str =
      cond do
        task.status == :passed and task.streak > 1 ->
          "#{IO.ANSI.faint()}(streak: #{task.streak})#{IO.ANSI.reset()}"

        task.status == :failed ->
          "#{IO.ANSI.faint()}(streak: 0)#{IO.ANSI.reset()}"

        true ->
          ""
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
        display_error(reason)
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
        display_error(reason)
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

      {:error, reason} ->
        display_error(reason)
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

  # ----- ERROR DISPLAY -----

  # Display a structured error with Rust-style formatting
  defp display_error(%Error{} = error) do
    IO.puts("")
    IO.puts(Formatter.format(error))
    IO.puts("")
  end

  defp display_error(reason) do
    error = Error.wrap(reason)
    display_error(error)
  end

  # Halt with proper stdout flushing (needed for Burrito releases)
  defp halt(code) do
    :erlang.halt(code, flush: true)
  end
end
