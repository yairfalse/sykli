defmodule Sykli.Query.Runs do
  @moduledoc """
  Run history queries: last run, last good, recent runs.
  """

  alias Sykli.RunHistory

  @spec execute(atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def execute(timeframe, path) do
    case timeframe do
      :latest -> last_run(path)
      :last_good -> last_good_run(path)
      :today -> runs_in_range(path, :today, -1)
      :recent -> runs_in_range(path, :recent, -7)
    end
  end

  defp last_run(path) do
    case RunHistory.load_latest(path: path) do
      {:ok, run} ->
        {:ok, %{
          type: :runs,
          data: %{query: :latest, run: serialize_run(run)},
          metadata: metadata("last run")
        }}

      {:error, _} ->
        {:error, :no_runs}
    end
  end

  defp last_good_run(path) do
    case RunHistory.load_last_good(path: path) do
      {:ok, run} ->
        {:ok, %{
          type: :runs,
          data: %{query: :last_good, run: serialize_run(run)},
          metadata: metadata("last good run")
        }}

      {:error, _} ->
        {:error, :no_runs}
    end
  end

  defp runs_in_range(path, query_atom, days_offset) do
    cutoff = DateTime.utc_now() |> DateTime.add(days_offset, :day)

    with {:ok, runs} <- RunHistory.list(path: path, limit: 50) do
      recent = Enum.filter(runs, &(DateTime.compare(&1.timestamp, cutoff) == :gt))

      {:ok, %{
        type: :runs,
        data: %{
          query: query_atom,
          count: length(recent),
          runs: Enum.map(recent, &serialize_run_summary/1)
        },
        metadata: metadata(Atom.to_string(query_atom) |> String.replace("_", " "))
      }}
    end
  end

  defp serialize_run(run) do
    %{
      id: run.id,
      timestamp: DateTime.to_iso8601(run.timestamp),
      git_ref: run.git_ref,
      git_branch: run.git_branch,
      overall: run.overall,
      tasks:
        Enum.map(run.tasks, fn t ->
          result = %{
            name: t.name,
            status: t.status,
            duration_ms: t.duration_ms,
            cached: t.cached == true
          }

          if t.error, do: Map.put(result, :error, t.error), else: result
        end)
    }
  end

  defp serialize_run_summary(run) do
    %{
      id: run.id,
      timestamp: DateTime.to_iso8601(run.timestamp),
      overall: run.overall,
      task_count: length(run.tasks),
      passed: Enum.count(run.tasks, &(&1.status == :passed)),
      failed: Enum.count(run.tasks, &(&1.status == :failed))
    }
  end

  defp metadata(query) do
    %{query: query, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}
  end
end
