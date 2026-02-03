defmodule Sykli.Services.ProgressTracker do
  @moduledoc """
  Service for tracking task execution progress.

  Provides a centralized way to track progress across parallel task execution,
  with thread-safe counter operations.
  """

  use Agent

  @type progress :: {completed :: non_neg_integer(), total :: non_neg_integer()}

  @doc """
  Starts a new progress tracker.

  ## Options

    * `:initial` - Initial completed count (default: 0)
    * `:total` - Total task count (required)

  ## Example

      {:ok, tracker} = ProgressTracker.start_link(total: 10)

  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    initial = Keyword.get(opts, :initial, 0)
    total = Keyword.fetch!(opts, :total)
    Agent.start_link(fn -> {initial, total} end)
  end

  @doc """
  Gets the current progress as `{completed, total}`.
  """
  @spec get(pid()) :: progress()
  def get(tracker) do
    Agent.get(tracker, & &1)
  end

  @doc """
  Gets the current completed count.
  """
  @spec completed(pid()) :: non_neg_integer()
  def completed(tracker) do
    Agent.get(tracker, fn {completed, _} -> completed end)
  end

  @doc """
  Gets the total task count.
  """
  @spec total(pid()) :: non_neg_integer()
  def total(tracker) do
    Agent.get(tracker, fn {_, total} -> total end)
  end

  @doc """
  Increments the completed count and returns the new value.
  """
  @spec increment(pid()) :: non_neg_integer()
  def increment(tracker) do
    Agent.get_and_update(tracker, fn {completed, total} ->
      new_completed = completed + 1
      {new_completed, {new_completed, total}}
    end)
  end

  @doc """
  Increments the completed count and returns the progress as `{new_count, total}`.
  """
  @spec increment_and_get(pid()) :: progress()
  def increment_and_get(tracker) do
    Agent.get_and_update(tracker, fn {completed, total} ->
      new_completed = completed + 1
      {{new_completed, total}, {new_completed, total}}
    end)
  end

  @doc """
  Stops the progress tracker.
  """
  @spec stop(pid()) :: :ok
  def stop(tracker) do
    Agent.stop(tracker)
  end

  @doc """
  Formats progress as a string like "[3/10]".
  """
  @spec format(progress()) :: String.t()
  def format({completed, total}) do
    "[#{completed}/#{total}]"
  end

  @doc """
  Formats progress with ANSI styling for terminal output.
  """
  @spec format_styled(progress()) :: String.t()
  def format_styled({completed, total}) do
    "#{IO.ANSI.faint()}[#{completed}/#{total}]#{IO.ANSI.reset()}"
  end

  @doc """
  Formats progress as a percentage.
  """
  @spec format_percent(progress()) :: String.t()
  def format_percent({completed, total}) when total > 0 do
    percent = Float.round(completed / total * 100, 1)
    "#{percent}%"
  end

  def format_percent({_, 0}), do: "0%"
end
