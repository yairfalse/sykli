defmodule Sykli.Graph.Task.HistoryHint do
  @moduledoc """
  Learned historical data about task behavior.

  This value object is populated by Sykli from run history, not by SDKs.
  It provides AI assistants with context about task reliability and patterns.

  ## Example

      %HistoryHint{
        flaky: true,
        avg_duration_ms: 3200,
        failure_patterns: ["connection timeout", "race condition"],
        pass_rate: 0.95,
        last_failure: ~U[2024-01-15 10:30:00Z]
      }

  ## Usage

  AI assistants can use this information to:
  - Deprioritize flaky tests
  - Understand expected duration
  - Recognize known failure patterns
  - Make informed retry decisions
  """

  @type t :: %__MODULE__{
          flaky: boolean(),
          avg_duration_ms: non_neg_integer() | nil,
          failure_patterns: [String.t()],
          pass_rate: float() | nil,
          last_failure: DateTime.t() | nil,
          streak: integer()
        }

  @enforce_keys []
  defstruct flaky: false,
            avg_duration_ms: nil,
            failure_patterns: [],
            pass_rate: nil,
            last_failure: nil,
            streak: 0

  @doc """
  Creates a HistoryHint struct from a map (parsed JSON).
  """
  @spec from_map(map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}

  def from_map(map) when is_map(map) do
    %__MODULE__{
      flaky: map["flaky"] == true,
      avg_duration_ms: map["avg_duration_ms"],
      failure_patterns: map["failure_patterns"] || [],
      pass_rate: map["pass_rate"],
      last_failure: parse_datetime(map["last_failure"]),
      streak: map["streak"] || 0
    }
  end

  @doc """
  Converts a HistoryHint struct to a map for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = hint) do
    base = %{
      "flaky" => hint.flaky,
      "avg_duration_ms" => hint.avg_duration_ms,
      "failure_patterns" => hint.failure_patterns,
      "pass_rate" => hint.pass_rate,
      "last_failure" => format_datetime(hint.last_failure),
      "streak" => hint.streak
    }

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

  @doc """
  Creates a HistoryHint from run history data.

  Takes a list of task results from previous runs and computes
  the learned hints.
  """
  @spec from_history([map()]) :: t()
  def from_history([]), do: %__MODULE__{}

  def from_history(results) do
    durations = Enum.map(results, & &1[:duration_ms]) |> Enum.reject(&is_nil/1)
    statuses = Enum.map(results, & &1[:status])

    pass_count = Enum.count(statuses, &(&1 == :passed))
    total_count = length(statuses)

    # Flaky = has both passes and failures in recent history
    has_passes = pass_count > 0
    has_failures = pass_count < total_count
    flaky = has_passes and has_failures

    # Compute current streak (consecutive same status from most recent)
    streak = compute_streak(statuses)

    # Find failure patterns from error messages
    failure_patterns =
      results
      |> Enum.filter(&(&1[:status] == :failed))
      |> Enum.map(& &1[:error])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(5)

    # Find last failure
    last_failure =
      results
      |> Enum.filter(&(&1[:status] == :failed))
      |> Enum.map(& &1[:timestamp])
      |> Enum.max(DateTime, fn -> nil end)

    %__MODULE__{
      flaky: flaky,
      avg_duration_ms: safe_avg(durations),
      failure_patterns: failure_patterns,
      pass_rate: if(total_count > 0, do: pass_count / total_count, else: nil),
      last_failure: last_failure,
      streak: streak
    }
  end

  @doc """
  Returns true if the task is marked as flaky.
  """
  @spec flaky?(t()) :: boolean()
  def flaky?(%__MODULE__{flaky: f}), do: f

  @doc """
  Returns true if any failure pattern matches the given error.
  """
  @spec matches_known_failure?(t(), String.t()) :: boolean()
  def matches_known_failure?(%__MODULE__{failure_patterns: []}, _error), do: false

  def matches_known_failure?(%__MODULE__{failure_patterns: patterns}, error) do
    error_lower = String.downcase(error)

    Enum.any?(patterns, fn pattern ->
      String.contains?(error_lower, String.downcase(pattern))
    end)
  end

  # Private helpers

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp safe_avg([]), do: nil
  defp safe_avg(list), do: round(Enum.sum(list) / length(list))

  defp compute_streak([]), do: 0

  defp compute_streak([first | rest]) do
    consecutive = Enum.take_while(rest, &(&1 == first)) |> length()
    count = 1 + consecutive
    if first == :passed, do: count, else: -count
  end
end
