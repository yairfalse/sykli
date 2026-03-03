defmodule Sykli.Query.Health do
  @moduledoc """
  Health queries: flaky tasks, failure rates, slowest tasks.
  """

  alias Sykli.RunHistory

  @spec execute(atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def execute(metric, path) do
    with {:ok, runs} <- load_runs(path) do
      case metric do
        :flaky -> flaky_tasks(runs)
        :failure_rate -> failure_rate(runs)
        :slowest -> slowest_tasks(runs)
        :summary -> health_summary(runs)
      end
    end
  end

  defp flaky_tasks(runs) do
    flaky =
      runs
      |> Enum.flat_map(& &1.tasks)
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_name, results} ->
        statuses = MapSet.new(results, & &1.status)
        MapSet.member?(statuses, :passed) and MapSet.member?(statuses, :failed)
      end)
      |> Enum.map(fn {name, results} ->
        total = length(results)
        failures = Enum.count(results, &(&1.status == :failed))

        %{
          name: name,
          total_runs: total,
          failures: failures,
          flake_rate: Float.round(failures / total, 2)
        }
      end)
      |> Enum.sort_by(& &1.flake_rate, :desc)

    {:ok,
     %{
       type: :health,
       data: %{metric: :flaky, tasks: flaky, total: length(flaky)},
       metadata: metadata("flaky tasks")
     }}
  end

  defp failure_rate(runs) do
    total = length(runs)
    passed = Enum.count(runs, &(&1.overall == :passed))

    {:ok,
     %{
       type: :health,
       data: %{
         metric: :failure_rate,
         total_runs: total,
         passed: passed,
         failed: total - passed,
         success_rate: if(total > 0, do: Float.round(passed / total, 2), else: 0.0)
       },
       metadata: metadata("failure rate")
     }}
  end

  defp slowest_tasks(runs) do
    stats =
      runs
      |> Enum.flat_map(& &1.tasks)
      |> Enum.group_by(& &1.name)
      |> Enum.map(fn {name, results} ->
        durations = Enum.map(results, &(&1.duration_ms || 0))
        avg = div(Enum.sum(durations), length(durations))

        %{
          name: name,
          avg_ms: avg,
          max_ms: Enum.max(durations),
          runs: length(results)
        }
      end)
      |> Enum.sort_by(& &1.avg_ms, :desc)
      |> Enum.take(10)

    {:ok,
     %{
       type: :health,
       data: %{metric: :slowest, tasks: stats},
       metadata: metadata("slowest tasks")
     }}
  end

  defp health_summary(runs) do
    total = length(runs)
    passed = Enum.count(runs, &(&1.overall == :passed))

    durations =
      Enum.map(runs, fn run ->
        Enum.reduce(run.tasks, 0, fn t, acc -> acc + (t.duration_ms || 0) end)
      end)

    avg_duration = if total > 0, do: div(Enum.sum(durations), total), else: 0

    last_success =
      runs
      |> Enum.find(&(&1.overall == :passed))
      |> case do
        nil -> nil
        run -> DateTime.to_iso8601(run.timestamp)
      end

    flaky_count =
      runs
      |> Enum.flat_map(& &1.tasks)
      |> Enum.group_by(& &1.name)
      |> Enum.count(fn {_name, results} ->
        statuses = MapSet.new(results, & &1.status)
        MapSet.member?(statuses, :passed) and MapSet.member?(statuses, :failed)
      end)

    {:ok,
     %{
       type: :health,
       data: %{
         metric: :summary,
         recent_runs: total,
         success_rate: if(total > 0, do: Float.round(passed / total, 2), else: 0.0),
         avg_duration_ms: avg_duration,
         last_success: last_success,
         flaky_task_count: flaky_count
       },
       metadata: metadata("health")
     }}
  end

  defp load_runs(path) do
    case RunHistory.list(path: path, limit: 50) do
      {:ok, []} -> {:error, :no_runs}
      {:ok, runs} -> {:ok, runs}
      {:error, _} -> {:error, :no_runs}
    end
  end

  defp metadata(query) do
    %{query: query, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}
  end
end
