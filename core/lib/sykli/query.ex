defmodule Sykli.Query do
  @moduledoc """
  Structured query engine for Sykli context and history.

  Supports keyword-based queries without requiring an LLM.
  Queries are classified via string pattern matching and routed
  to specialized handler modules.

  ## Query Categories

      "what tests cover auth"       → Coverage.execute/2
      "why did build fail"          → History.why_failed/3
      "what's flaky"                → Health.execute/2
      "critical tasks"              → Tasks.execute/3
      "last run"                    → Runs.execute/2

  ## Extensibility

  To add a new query pattern, add a clause to `classify/1` and
  implement the handler. To add LLM support later, wrap `classify/1`
  with an NL→keywords mapper.
  """

  alias Sykli.Query.{Coverage, History, Health, Tasks, Runs}

  @type result :: %{
          type: atom(),
          data: map(),
          metadata: %{query: String.t(), timestamp: String.t()}
        }

  @doc """
  Execute a query string against the project at `path`.
  """
  @spec execute(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def execute(query_str, opts \\ []) do
    path = Keyword.get(opts, :path, ".")
    normalized = query_str |> String.trim() |> String.downcase()

    case classify(normalized) do
      {:coverage, pattern} ->
        Coverage.execute(pattern, path)

      {:failure, task_name, timeframe} ->
        History.why_failed(task_name, timeframe, path)

      {:last_pass, task_name} ->
        History.last_pass(task_name, path)

      {:health, metric} ->
        Health.execute(metric, path)

      {:tasks, query_type, target} ->
        Tasks.execute(query_type, target, path)

      {:runs, timeframe} ->
        Runs.execute(timeframe, path)

      :unknown ->
        {:error, {:unknown_query, query_str}}
    end
  end

  @doc """
  Classify a query string into a typed tuple for routing.

  Returns tagged tuples like `{:coverage, "auth"}` or `:unknown`.
  """
  @spec classify(String.t()) ::
          {:coverage, String.t()}
          | {:failure, String.t(), atom()}
          | {:last_pass, String.t()}
          | {:health, atom()}
          | {:tasks, atom(), String.t() | nil}
          | {:runs, atom()}
          | :unknown

  # Coverage
  def classify("what tests cover " <> pattern), do: {:coverage, String.trim(pattern)}
  def classify("what covers " <> pattern), do: {:coverage, String.trim(pattern)}
  def classify("coverage for " <> pattern), do: {:coverage, String.trim(pattern)}
  def classify("covers " <> pattern), do: {:coverage, String.trim(pattern)}

  # Failure analysis
  def classify("why did " <> rest), do: parse_failure_query(rest)

  # Last pass
  def classify("when did " <> rest), do: parse_last_pass_query(rest)

  # Health
  def classify("what's flaky"), do: {:health, :flaky}
  def classify("whats flaky"), do: {:health, :flaky}
  def classify("flaky tasks"), do: {:health, :flaky}
  def classify("flaky"), do: {:health, :flaky}
  def classify("failure rate"), do: {:health, :failure_rate}
  def classify("success rate"), do: {:health, :failure_rate}
  def classify("health"), do: {:health, :summary}
  def classify("slowest tasks"), do: {:health, :slowest}
  def classify("slow tasks"), do: {:health, :slowest}
  def classify("slowest"), do: {:health, :slowest}

  # Task queries
  def classify("critical tasks"), do: {:tasks, :critical, nil}
  def classify("critical"), do: {:tasks, :critical, nil}
  def classify("dependencies of " <> task), do: {:tasks, :deps, String.trim(task)}
  def classify("deps of " <> task), do: {:tasks, :deps, String.trim(task)}
  def classify("what depends on " <> task), do: {:tasks, :dependents, String.trim(task)}
  def classify("dependents of " <> task), do: {:tasks, :dependents, String.trim(task)}
  def classify("what blocks " <> task), do: {:tasks, :dependents, String.trim(task)}
  def classify("task " <> task), do: {:tasks, :details, String.trim(task)}
  def classify("tasks covering " <> pattern), do: {:coverage, String.trim(pattern)}
  def classify("tasks in level " <> level), do: {:tasks, :level, String.trim(level)}
  def classify("path from " <> rest), do: parse_path_query(rest)

  # Run queries
  def classify("last run"), do: {:runs, :latest}
  def classify("last good run"), do: {:runs, :last_good}
  def classify("last passing run"), do: {:runs, :last_good}
  def classify("runs today"), do: {:runs, :today}
  def classify("recent runs"), do: {:runs, :recent}

  def classify(_), do: :unknown

  # -- Helpers for multi-word patterns --

  defp parse_failure_query(rest) do
    cond do
      String.ends_with?(rest, " fail yesterday") ->
        task = String.replace_suffix(rest, " fail yesterday", "") |> String.trim()
        {:failure, task, :yesterday}

      String.ends_with?(rest, " fail today") ->
        task = String.replace_suffix(rest, " fail today", "") |> String.trim()
        {:failure, task, :today}

      String.ends_with?(rest, " fail") ->
        task = String.replace_suffix(rest, " fail", "") |> String.trim()
        {:failure, task, :latest}

      true ->
        :unknown
    end
  end

  defp parse_path_query(rest) do
    case String.split(rest, " to ", parts: 2) do
      [from, to] -> {:tasks, :path, {String.trim(from), String.trim(to)}}
      _ -> :unknown
    end
  end

  defp parse_last_pass_query(rest) do
    cond do
      String.ends_with?(rest, " last pass") ->
        task = String.replace_suffix(rest, " last pass", "") |> String.trim()
        {:last_pass, task}

      String.ends_with?(rest, " last succeed") ->
        task = String.replace_suffix(rest, " last succeed", "") |> String.trim()
        {:last_pass, task}

      true ->
        :unknown
    end
  end

  @doc """
  Format an error for display.
  """
  def format_error({:unknown_query, query}) do
    "Unknown query: \"#{query}\"\nRun 'sykli query --help' for supported queries."
  end

  def format_error({:task_not_found, name}), do: "Task '#{name}' not found in pipeline."
  def format_error({:no_failure_found, name}), do: "No recent failure found for task '#{name}'."
  def format_error({:no_pass_found, name}), do: "No recent pass found for task '#{name}'."
  def format_error(:no_runs), do: "No run history found. Run your pipeline first."
  def format_error({:no_sdk_file, _}), do: "No sykli file found. Run 'sykli init' first."
  def format_error(reason), do: inspect(reason)
end
