defmodule Sykli.Occurrence.HistoryAnalyzer do
  @moduledoc """
  Computes per-task history statistics from recent runs.

  Reuses `RunHistory.list/1` to load runs and `HistoryHint.from_history/1`
  to compute stats (flakiness, avg_duration, pass_rate, streak, patterns).
  """

  alias Sykli.RunHistory
  alias Sykli.Graph.Task.HistoryHint

  @doc """
  Analyzes history for the given task names.

  Returns a map of task_name => history stats map.
  """
  @spec analyze([String.t()], String.t(), pos_integer()) :: %{String.t() => map()}
  def analyze(task_names, workdir, max_runs \\ 20) do
    case RunHistory.list(path: workdir, limit: max_runs) do
      {:ok, runs} ->
        task_names
        |> Map.new(fn name ->
          results = extract_task_results(runs, name)
          hint = HistoryHint.from_history(results)
          {name, hint_to_map(hint)}
        end)

      {:error, _} ->
        Map.new(task_names, &{&1, %{}})
    end
  end

  # Extract a task's results across runs (most recent first)
  defp extract_task_results(runs, task_name) do
    Enum.flat_map(runs, fn run ->
      case Enum.find(run.tasks, &(&1.name == task_name)) do
        nil ->
          []

        task_result ->
          [
            %{
              status: task_result.status,
              duration_ms: task_result.duration_ms,
              error: task_result.error,
              timestamp: run.timestamp
            }
          ]
      end
    end)
  end

  defp hint_to_map(%HistoryHint{} = hint) do
    base = %{
      "streak" => hint.streak,
      "avg_duration_ms" => hint.avg_duration_ms,
      "pass_rate" => hint.pass_rate,
      "flaky" => hint.flaky,
      "failure_patterns" => hint.failure_patterns,
      "last_failure" => format_datetime(hint.last_failure)
    }

    # Remove nil/empty values for cleaner output
    base
    |> Enum.reject(fn
      {_k, nil} -> true
      {_k, []} -> true
      {"flaky", false} -> true
      {"streak", 0} -> true
      _ -> false
    end)
    |> Map.new()
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
