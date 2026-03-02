defmodule Sykli.Query.History do
  @moduledoc """
  History queries: why did X fail, when did X last pass.
  """

  alias Sykli.RunHistory

  @spec why_failed(String.t(), atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def why_failed(task_name, timeframe, path) do
    with {:ok, runs} <- RunHistory.list(path: path, limit: 50) do
      runs_in_range = filter_by_timeframe(runs, timeframe)
      find_failure(task_name, runs_in_range)
    end
  end

  @spec last_pass(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def last_pass(task_name, path) do
    with {:ok, runs} <- RunHistory.list(path: path, limit: 50) do
      result =
        Enum.find_value(runs, fn run ->
          task = Enum.find(run.tasks, &(&1.name == task_name and &1.status == :passed))
          if task, do: {run, task}
        end)

      case result do
        {run, task} ->
          {:ok, %{
            type: :history,
            data: %{
              task: task_name,
              status: :passed,
              duration_ms: task.duration_ms,
              run_id: run.id,
              timestamp: DateTime.to_iso8601(run.timestamp),
              git_ref: run.git_ref,
              git_branch: run.git_branch
            },
            metadata: metadata("when did #{task_name} last pass")
          }}

        nil ->
          {:error, {:no_pass_found, task_name}}
      end
    end
  end

  defp find_failure(task_name, runs) do
    result =
      Enum.find_value(runs, fn run ->
        task = Enum.find(run.tasks, &(&1.name == task_name and &1.status == :failed))
        if task, do: {run, task}
      end)

    case result do
      {run, task} ->
        {:ok, %{
          type: :history,
          data: %{
            task: task_name,
            status: :failed,
            error: task.error,
            duration_ms: task.duration_ms,
            run_id: run.id,
            timestamp: DateTime.to_iso8601(run.timestamp),
            git_ref: run.git_ref,
            git_branch: run.git_branch
          },
          metadata: metadata("why did #{task_name} fail")
        }}

      nil ->
        {:error, {:no_failure_found, task_name}}
    end
  end

  defp filter_by_timeframe(runs, :latest), do: runs

  defp filter_by_timeframe(runs, :yesterday) do
    yesterday = Date.add(Date.utc_today(), -1)

    Enum.filter(runs, fn run ->
      DateTime.to_date(run.timestamp) == yesterday
    end)
  end

  defp filter_by_timeframe(runs, :today) do
    today = DateTime.utc_now() |> DateTime.to_date()

    Enum.filter(runs, fn run ->
      DateTime.to_date(run.timestamp) == today
    end)
  end

  defp metadata(query) do
    %{query: query, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}
  end
end
