defmodule Sykli.Query.Output do
  @moduledoc """
  Human-readable terminal formatting for query results.
  """

  @spec format(map()) :: :ok

  # -- Coverage --

  def format(%{type: :coverage, data: %{pattern: pattern, tasks: tasks}}) do
    header("Coverage for: #{pattern}")

    if tasks == [] do
      faint("  No tasks cover this pattern")
    else
      Enum.each(tasks, fn task ->
        IO.puts("  #{green("*")} #{task.name}")
        if task.intent, do: faint("    #{task.intent}")
        if task.covers != [], do: faint("    covers: #{Enum.join(task.covers, ", ")}")
      end)
    end

    IO.puts("")
  end

  # -- History: failure --

  def format(%{type: :history, data: %{status: :failed} = data}) do
    header("Failure: #{data.task}")
    IO.puts("  Status:  #{red("failed")}")
    if data[:error], do: IO.puts("  Error:   #{red(data.error)}")
    IO.puts("  Run:     #{data.run_id}")
    IO.puts("  When:    #{data.timestamp}")
    if data[:git_ref], do: faint("  Ref:     #{data.git_ref}")
    if data[:git_branch], do: faint("  Branch:  #{data.git_branch}")
    IO.puts("")
  end

  # -- History: last pass --

  def format(%{type: :history, data: %{status: :passed} = data}) do
    header("Last pass: #{data.task}")
    IO.puts("  Status:  #{green("passed")}")
    if data[:duration_ms], do: IO.puts("  Duration: #{format_duration(data.duration_ms)}")
    IO.puts("  When:    #{data.timestamp}")
    if data[:git_ref], do: faint("  Ref:     #{data.git_ref}")
    if data[:git_branch], do: faint("  Branch:  #{data.git_branch}")
    IO.puts("")
  end

  # -- Health: flaky --

  def format(%{type: :health, data: %{metric: :flaky, tasks: tasks}}) do
    header("Flaky Tasks")

    if tasks == [] do
      IO.puts("  #{green("No flaky tasks detected")}")
    else
      Enum.each(tasks, fn task ->
        pct = Float.round(task.flake_rate * 100, 1)
        IO.puts("  #{yellow("*")} #{task.name}")
        faint("    #{task.failures}/#{task.total_runs} failures (#{pct}%)")
      end)
    end

    IO.puts("")
  end

  # -- Health: failure rate --

  def format(%{type: :health, data: %{metric: :failure_rate} = data}) do
    header("Pipeline Health")
    IO.puts("  Total runs:    #{data.total_runs}")
    IO.puts("  Passed:        #{green(to_string(data.passed))}")
    IO.puts("  Failed:        #{red(to_string(data.failed))}")
    IO.puts("  Success rate:  #{format_rate(data.success_rate)}")
    IO.puts("")
  end

  # -- Health: summary --

  def format(%{type: :health, data: %{metric: :summary} = data}) do
    header("Health Summary")
    IO.puts("  Recent runs:   #{data.recent_runs}")
    IO.puts("  Success rate:  #{format_rate(data.success_rate)}")
    IO.puts("  Avg duration:  #{format_duration(data.avg_duration_ms)}")

    if data[:last_success] do
      IO.puts("  Last success:  #{data.last_success}")
    else
      IO.puts("  Last success:  #{red("never")}")
    end

    IO.puts("  Flaky tasks:   #{data.flaky_task_count}")
    IO.puts("")
  end

  # -- Health: slowest --

  def format(%{type: :health, data: %{metric: :slowest, tasks: tasks}}) do
    header("Slowest Tasks")

    Enum.each(tasks, fn task ->
      IO.puts("  #{task.name}")
      faint("    avg: #{format_duration(task.avg_ms)}, max: #{format_duration(task.max_ms)}")
    end)

    IO.puts("")
  end

  # -- Tasks: critical --

  def format(%{type: :tasks, data: %{query: :critical, tasks: tasks}}) do
    header("Critical Tasks")

    if tasks == [] do
      faint("  No tasks marked as critical")
    else
      Enum.each(tasks, fn task ->
        IO.puts("  #{red("*")} #{task.name}")
        if task.intent, do: faint("    #{task.intent}")
      end)
    end

    IO.puts("")
  end

  # -- Tasks: dependencies --

  def format(%{type: :tasks, data: %{query: :deps, task: task, dependencies: deps}}) do
    header("Dependencies of #{task}")

    if deps == [] do
      faint("  No dependencies (runs first)")
    else
      Enum.each(deps, fn dep -> IO.puts("  #{green("*")} #{dep}") end)
    end

    IO.puts("")
  end

  # -- Tasks: dependents --

  def format(%{type: :tasks, data: %{query: :dependents, task: task, dependents: deps}}) do
    header("Blocked by #{task}")

    if deps == [] do
      faint("  Nothing depends on this task")
    else
      Enum.each(deps, fn dep -> IO.puts("  #{green("*")} #{dep}") end)
    end

    IO.puts("")
  end

  # -- Tasks: details --

  def format(%{type: :tasks, data: %{query: :details, task: task}}) do
    header("Task: #{task["name"]}")
    IO.puts("  Command:   #{task["command"]}")

    deps = task["depends_on"] || []
    if deps != [], do: IO.puts("  Depends:   #{Enum.join(deps, ", ")}")
    if task["workdir"], do: IO.puts("  Workdir:   #{task["workdir"]}")
    if task["container"], do: IO.puts("  Container: #{task["container"]}")
    if task["timeout"], do: IO.puts("  Timeout:   #{task["timeout"]}s")

    if task["semantic"] do
      s = task["semantic"]
      if s["intent"], do: IO.puts("  Intent:    #{s["intent"]}")

      if s["covers"] && s["covers"] != [],
        do: IO.puts("  Covers:    #{Enum.join(s["covers"], ", ")}")

      if s["criticality"], do: IO.puts("  Critical:  #{s["criticality"]}")
    end

    IO.puts("")
  end

  # -- Runs: single run --

  def format(%{type: :runs, data: %{run: run}}) do
    label =
      case run.overall do
        :passed -> green("passed")
        :failed -> red("failed")
        other -> to_string(other)
      end

    header("Run #{run.id}")
    IO.puts("  Status:  #{label}")
    IO.puts("  When:    #{run.timestamp}")
    if run[:git_branch], do: IO.puts("  Branch:  #{run.git_branch}")
    if run[:git_ref], do: faint("  Ref:     #{run.git_ref}")
    IO.puts("")

    Enum.each(run.tasks, fn task ->
      icon =
        case task.status do
          :passed -> green("v")
          :failed -> red("x")
          _ -> "o"
        end

      cached = if task.cached, do: " #{yellow("(cached)")}", else: ""
      dur = if task.duration_ms, do: " #{format_duration(task.duration_ms)}", else: ""
      IO.puts("    #{icon} #{task.name}#{dur}#{cached}")
    end)

    IO.puts("")
  end

  # -- Runs: list --

  def format(%{type: :runs, data: %{count: count, runs: runs}}) do
    header("Runs (#{count})")

    if runs == [] do
      faint("  No runs found")
    else
      Enum.each(runs, fn run ->
        icon = if run.overall == :passed, do: green("v"), else: red("x")
        IO.puts("  #{icon} #{run.timestamp}  #{run.passed}/#{run.task_count} passed")
      end)
    end

    IO.puts("")
  end

  # -- Helpers --

  defp header(text), do: IO.puts("\n#{cyan(text)}")
  defp faint(text), do: IO.puts("#{IO.ANSI.faint()}#{text}#{IO.ANSI.reset()}")

  defp green(text), do: "#{IO.ANSI.green()}#{text}#{IO.ANSI.reset()}"
  defp red(text), do: "#{IO.ANSI.red()}#{text}#{IO.ANSI.reset()}"
  defp yellow(text), do: "#{IO.ANSI.yellow()}#{text}#{IO.ANSI.reset()}"
  defp cyan(text), do: "#{IO.ANSI.cyan()}#{text}#{IO.ANSI.reset()}"

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp format_rate(rate) do
    pct = Float.round(rate * 100, 1)

    cond do
      rate >= 0.9 -> green("#{pct}%")
      rate >= 0.7 -> yellow("#{pct}%")
      true -> red("#{pct}%")
    end
  end
end
