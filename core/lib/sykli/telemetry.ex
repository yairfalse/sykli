defmodule Sykli.Telemetry do
  @moduledoc """
  Telemetry event definitions and optional default log handler.

  Events:
  - `[:sykli, :task, :start]` — Task execution started
  - `[:sykli, :task, :stop]` — Task execution completed (measurements: duration)
  - `[:sykli, :task, :exception]` — Task execution raised
  - `[:sykli, :cache, :check]` — Cache check (metadata: result, reason)
  - `[:sykli, :run, :start]` — Run started
  - `[:sykli, :run, :stop]` — Run completed (measurements: duration, task_count)

  ## Usage

  Attach your own handler:

      :telemetry.attach("my-handler", [:sykli, :task, :stop], &MyModule.handle_event/4, nil)

  Or use the default log handler:

      Sykli.Telemetry.attach_default_handler()
  """

  require Logger

  @task_start [:sykli, :task, :start]
  @task_stop [:sykli, :task, :stop]
  @task_exception [:sykli, :task, :exception]
  @cache_check [:sykli, :cache, :check]
  @run_start [:sykli, :run, :start]
  @run_stop [:sykli, :run, :stop]

  @doc "All telemetry events emitted by Sykli."
  def events do
    [@task_start, @task_stop, @task_exception, @cache_check, @run_start, @run_stop]
  end

  @doc "Execute a function within a telemetry span for task execution."
  def span_task(task_name, metadata, fun) do
    :telemetry.span(
      [:sykli, :task],
      Map.merge(%{task: task_name}, metadata),
      fn ->
        result = fun.()
        {result, %{task: task_name}}
      end
    )
  end

  @doc "Emit a cache check event."
  def emit_cache_check(task_name, result, reason \\ nil) do
    :telemetry.execute(
      @cache_check,
      %{system_time: System.system_time()},
      %{task: task_name, result: result, reason: reason}
    )
  end

  @doc "Emit a run start event."
  def emit_run_start(run_id, task_count) do
    :telemetry.execute(
      @run_start,
      %{system_time: System.system_time()},
      %{run_id: run_id, task_count: task_count}
    )
  end

  @doc "Emit a run stop event."
  def emit_run_stop(run_id, task_count, duration_ms, status) do
    :telemetry.execute(
      @run_stop,
      %{duration: duration_ms, task_count: task_count},
      %{run_id: run_id, status: status}
    )
  end

  @doc "Attach the default log handler that logs events at :debug level."
  def attach_default_handler do
    events = [
      @task_stop,
      @cache_check,
      @run_start,
      @run_stop
    ]

    :telemetry.attach_many("sykli-default-logger", events, &handle_event/4, nil)
  end

  @doc false
  def handle_event([:sykli, :task, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.debug("[telemetry] task #{metadata.task} completed in #{duration_ms}ms")
  end

  def handle_event([:sykli, :cache, :check], _measurements, metadata, _config) do
    Logger.debug("[telemetry] cache #{metadata.result} for #{metadata.task}")
  end

  def handle_event([:sykli, :run, :start], _measurements, metadata, _config) do
    Logger.debug("[telemetry] run #{metadata.run_id} started with #{metadata.task_count} tasks")
  end

  def handle_event([:sykli, :run, :stop], measurements, metadata, _config) do
    Logger.debug(
      "[telemetry] run #{metadata.run_id} #{metadata.status} in #{System.convert_time_unit(measurements.duration, :native, :millisecond)}ms"
    )
  end
end
