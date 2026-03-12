defmodule Sykli.Services.PredictiveWarnings do
  @moduledoc """
  Scans tasks with history hints and emits warnings before execution.

  Detects:
  - Flaky tasks with pass rate below threshold
  - Tasks on a failing streak
  - Tasks with increasing duration trend (when available)
  """

  alias Sykli.Graph.Task.HistoryHint

  @flaky_threshold 0.80
  @failing_streak_threshold 2

  @type warning :: %{task: String.t(), type: atom(), message: String.t()}

  @doc """
  Scans a task graph for predictive warnings based on history hints.

  Returns a list of warning maps, each with `:task`, `:type`, and `:message`.
  """
  @spec scan(map()) :: [warning()]
  def scan(graph) when is_map(graph) do
    graph
    |> Enum.flat_map(fn {_name, task} -> warnings_for_task(task) end)
  end

  @doc """
  Prints warnings to stderr (non-blocking, informational only).
  """
  @spec print_warnings([warning()]) :: :ok
  def print_warnings([]), do: :ok

  def print_warnings(warnings) do
    IO.puts(:stderr, "\n#{IO.ANSI.yellow()}⚠ Predictive warnings:#{IO.ANSI.reset()}")

    Enum.each(warnings, fn w ->
      IO.puts(:stderr, "  #{IO.ANSI.faint()}• #{w.message}#{IO.ANSI.reset()}")
    end)

    IO.puts(:stderr, "")
    :ok
  end

  defp warnings_for_task(%{name: name, history_hint: %HistoryHint{} = hint}) do
    []
    |> maybe_warn_flaky(name, hint)
    |> maybe_warn_failing_streak(name, hint)
    |> maybe_warn_duration_trend(name, hint)
  end

  defp warnings_for_task(_), do: []

  defp maybe_warn_flaky(warnings, name, %HistoryHint{flaky: true, pass_rate: rate})
       when is_number(rate) and rate < @flaky_threshold do
    pct = round(rate * 100)

    [
      %{task: name, type: :flaky, message: "#{name} is flaky (#{pct}% pass rate)"}
      | warnings
    ]
  end

  defp maybe_warn_flaky(warnings, _name, _hint), do: warnings

  defp maybe_warn_failing_streak(warnings, name, %HistoryHint{streak: streak})
       when is_integer(streak) and streak <= -@failing_streak_threshold do
    [
      %{
        task: name,
        type: :failing_streak,
        message: "#{name} has failed #{abs(streak)} runs in a row"
      }
      | warnings
    ]
  end

  defp maybe_warn_failing_streak(warnings, _name, _hint), do: warnings

  defp maybe_warn_duration_trend(warnings, name, %HistoryHint{} = hint) do
    # Duration trend field is optional (added in 3.2)
    case Map.get(hint, :duration_trend) do
      :increasing ->
        [
          %{
            task: name,
            type: :duration_increasing,
            message: "#{name} duration is trending upward"
          }
          | warnings
        ]

      _ ->
        warnings
    end
  end
end
