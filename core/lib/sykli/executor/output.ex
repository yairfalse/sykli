defmodule Sykli.Executor.Output do
  @moduledoc """
  Stateless formatting module for executor CLI output.

  All IO.puts calls in the executor are routed through this module,
  decoupling orchestration logic from presentation.
  """

  @doc "Prints level header with task count and parallel indicator."
  def level_header(level_size, next_tasks) do
    IO.puts(
      "\n#{IO.ANSI.faint()}── Level with #{level_size} task(s)#{if level_size > 1, do: " (parallel)", else: ""} ──#{IO.ANSI.reset()}"
    )

    if length(next_tasks) > 0 do
      preview = Enum.take(next_tasks, 3) |> Enum.join(", ")
      more = if length(next_tasks) > 3, do: " +#{length(next_tasks) - 3} more", else: ""

      IO.puts("#{IO.ANSI.faint()}   next → #{preview}#{more}#{IO.ANSI.reset()}")
    end
  end

  @doc "Prints task starting message with progress and cache miss reason."
  def task_starting(prefix, name, reason_str) do
    IO.puts(
      "#{prefix}#{IO.ANSI.cyan()}▶ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(#{reason_str})#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints cached task indicator."
  def task_cached(prefix, name) do
    IO.puts(
      "#{prefix}#{IO.ANSI.yellow()}⊙ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}CACHED#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints skipped task indicator."
  def task_skipped(prefix, name, reason) do
    IO.puts(
      "#{prefix}#{IO.ANSI.faint()}○ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(skipped: #{reason})#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints task failure message when stopping."
  def task_failed_stopping(name) do
    IO.puts("#{IO.ANSI.red()}✗ #{name} failed, stopping#{IO.ANSI.reset()}")
  end

  @doc "Prints task failure message with detail."
  def task_failed(prefix, name, detail) do
    IO.puts(
      "#{prefix}#{IO.ANSI.red()}✗ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(#{detail})#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints task retry indicator."
  def task_retrying(name, attempt, max_attempts) do
    IO.puts(
      "#{IO.ANSI.yellow()}↻ #{name}#{IO.ANSI.reset()} " <>
        "#{IO.ANSI.faint()}(retry #{attempt}/#{max_attempts - 1})#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints continuing after failure message."
  def run_continuing(failed_count) do
    IO.puts("#{IO.ANSI.yellow()}! #{failed_count} task(s) failed, continuing#{IO.ANSI.reset()}")
  end

  @doc "Prints gate waiting indicator."
  def gate_waiting(prefix, name, strategy) do
    IO.puts(
      "#{prefix}#{IO.ANSI.yellow()}\u23F8 #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(gate: #{strategy})#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints gate approved indicator."
  def gate_approved(prefix, name, approver) do
    IO.puts(
      "#{prefix}#{IO.ANSI.green()}\u2713 #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(approved by #{approver})#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints gate denied indicator."
  def gate_denied(prefix, name, reason) do
    IO.puts(
      "#{prefix}#{IO.ANSI.red()}\u2717 #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(denied: #{reason})#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints gate timed out indicator."
  def gate_timed_out(prefix, name, timeout) do
    IO.puts(
      "#{prefix}#{IO.ANSI.red()}\u2717 #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(timed out after #{timeout}s)#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints service start failure."
  def service_start_failed(name, reason) do
    IO.puts(
      "#{IO.ANSI.red()}✗ #{name}#{IO.ANSI.reset()} #{IO.ANSI.faint()}(service start failed: #{inspect(reason)})#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints missing secrets error."
  def missing_secrets(name, secrets) do
    IO.puts(
      "#{IO.ANSI.red()}✗ #{name}#{IO.ANSI.reset()} " <>
        "#{IO.ANSI.faint()}(missing secrets: #{Enum.join(secrets, ", ")})#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints OIDC exchange failure."
  def oidc_failed(name, reason) do
    IO.puts(
      "#{IO.ANSI.red()}✗ #{name}#{IO.ANSI.reset()} " <>
        "#{IO.ANSI.faint()}(OIDC exchange failed: #{reason})#{IO.ANSI.reset()}"
    )
  end

  @doc "Prints the run summary with status graph."
  def summary(results, total_time, status, tasks) do
    if Enum.empty?(results) do
      :ok
    else
      IO.puts("\n#{IO.ANSI.faint()}─────────────────────────────────────────#{IO.ANSI.reset()}")

      result_map = build_result_map(results)
      task_maps = Enum.map(tasks, fn t -> %{name: t.name, depends_on: t.depends_on || []} end)
      IO.puts(Sykli.GraphViz.to_status_line(task_maps, result_map))
      IO.puts("")

      passed =
        Enum.count(results, fn %Sykli.Executor.TaskResult{status: s} ->
          s in [:passed, :cached]
        end)

      failed =
        Enum.count(results, fn %Sykli.Executor.TaskResult{status: s} -> s == :failed end)

      {icon, color} = if status == :ok, do: {"✓", IO.ANSI.green()}, else: {"✗", IO.ANSI.red()}

      IO.puts(
        "#{color}#{icon}#{IO.ANSI.reset()} " <>
          "#{IO.ANSI.bright()}#{passed} passed#{IO.ANSI.reset()}" <>
          if(failed > 0, do: ", #{IO.ANSI.red()}#{failed} failed#{IO.ANSI.reset()}", else: "") <>
          " #{IO.ANSI.faint()}in #{format_duration(total_time)}#{IO.ANSI.reset()}"
      )

      if length(results) > 3 do
        slowest =
          results
          |> Enum.filter(fn %Sykli.Executor.TaskResult{status: s} ->
            s in [:passed, :cached]
          end)
          |> Enum.sort_by(fn %Sykli.Executor.TaskResult{duration_ms: d} -> -d end)
          |> Enum.take(3)

        if length(slowest) > 0 do
          IO.puts("")
          IO.puts("#{IO.ANSI.faint()}Slowest:#{IO.ANSI.reset()}")

          Enum.each(slowest, fn %Sykli.Executor.TaskResult{name: name, duration_ms: duration} ->
            IO.puts("  #{IO.ANSI.faint()}#{format_duration(duration)}#{IO.ANSI.reset()} #{name}")
          end)
        end
      end

      IO.puts("")
    end
  end

  @doc "Prints a formatted error."
  def error(error) do
    IO.puts(Sykli.Error.Formatter.format_simple(error))
  end

  # -- Private helpers --

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp build_result_map(results) do
    results
    |> Enum.map(fn %Sykli.Executor.TaskResult{name: name, status: status} ->
      viz_status =
        case status do
          :passed -> :passed
          :cached -> :passed
          :failed -> :failed
          :skipped -> :skipped
          :blocked -> :skipped
        end

      {name, viz_status}
    end)
    |> Map.new()
  end
end
