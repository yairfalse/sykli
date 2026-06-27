defmodule Sykli.Executor.Output do
  @moduledoc """
  Configurable sink for executor presentation events.

  The executor emits presentation events — task starting/cached/skipped/failed,
  retry, gate state, run summary — through this module. **By default there is no
  sink, so the executor is silent.** Presentation of results is
  `Sykli.CLI.Renderer`'s job, applied by the CLI *after* the run from the
  structured `TaskResult`s.

  A sink can be registered to observe events live:

      config :sykli, :executor_output_sink, MySink

  where `MySink` implements (any subset of) `Sykli.Executor.Output.Sink`. This is
  the extension point for live terminal rendering and the local GUI feed
  (see #154).

  The legacy terminal live-print implementation that used to live here — which
  emitted non-canonical glyphs (`▶`/`✓`), the banned `"Level"` header, and a
  *second* run summary (the documented "one summary per run" regression) — was
  retired in #256. It was suppressed during `sykli run` (via a group-leader
  swap) but leaked into `sykli watch`/`delta` and risked corrupting the MCP
  stdout stream.
  """

  def level_header(level_size, next_tasks),
    do: notify(:level_header, [level_size, next_tasks])

  def task_starting(prefix, name, reason_str),
    do: notify(:task_starting, [prefix, name, reason_str])

  def task_cached(prefix, name), do: notify(:task_cached, [prefix, name])

  def task_skipped(prefix, name, reason), do: notify(:task_skipped, [prefix, name, reason])

  def task_failed_stopping(name), do: notify(:task_failed_stopping, [name])

  def task_failed(prefix, name, detail), do: notify(:task_failed, [prefix, name, detail])

  def task_retrying(name, attempt, max_attempts),
    do: notify(:task_retrying, [name, attempt, max_attempts])

  def run_continuing(failed_count), do: notify(:run_continuing, [failed_count])

  def gate_waiting(prefix, name, strategy), do: notify(:gate_waiting, [prefix, name, strategy])

  def gate_approved(prefix, name, approver),
    do: notify(:gate_approved, [prefix, name, approver])

  def gate_denied(prefix, name, reason), do: notify(:gate_denied, [prefix, name, reason])

  def gate_timed_out(prefix, name, timeout),
    do: notify(:gate_timed_out, [prefix, name, timeout])

  def service_start_failed(name, reason), do: notify(:service_start_failed, [name, reason])

  def missing_secrets(name, secrets), do: notify(:missing_secrets, [name, secrets])

  def oidc_failed(name, reason), do: notify(:oidc_failed, [name, reason])

  def summary(results, total_time, status, tasks),
    do: notify(:summary, [results, total_time, status, tasks])

  def error(error), do: notify(:error, [error])

  # Dispatch to the configured sink, if any. Callbacks are optional: an event a
  # sink doesn't implement is silently dropped. Return values and failures are
  # ignored because presentation observers must not change executor semantics.
  defp notify(fun, args) do
    case Application.get_env(:sykli, :executor_output_sink) do
      nil ->
        :ok

      mod ->
        if function_exported?(mod, fun, length(args)), do: safe_apply(mod, fun, args)
        :ok
    end
  end

  defp safe_apply(mod, fun, args) do
    apply(mod, fun, args)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
