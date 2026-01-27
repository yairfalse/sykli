defmodule Sykli.Error.Boundary do
  @moduledoc """
  Exception boundary for converting crashes to structured errors.

  This module provides utilities for wrapping code that might raise
  exceptions or exit abnormally, converting them to structured
  `Sykli.Error` results.

  ## Usage

  ```elixir
  # Wrap a function that might raise
  case Sykli.Error.Boundary.wrap(fn -> risky_operation() end) do
    {:ok, result} -> handle_success(result)
    {:error, %Sykli.Error{} = error} -> display_error(error)
  end

  # Wrap with context
  Sykli.Error.Boundary.wrap(
    fn -> parse_config() end,
    step: :parse,
    task: "config"
  )
  ```
  """

  alias Sykli.Error

  @doc """
  Wraps a function call, converting any exception or exit to a structured error.

  Returns `{:ok, result}` on success, or `{:error, %Sykli.Error{}}` on failure.

  Options:
  - `:step` - The pipeline step for context
  - `:task` - The task name for context
  """
  def wrap(fun, opts \\ []) when is_function(fun, 0) do
    try do
      case fun.() do
        {:ok, result} -> {:ok, result}
        {:error, %Error{} = e} -> {:error, maybe_add_context(e, opts)}
        {:error, reason} -> {:error, Error.wrap(reason) |> maybe_add_context(opts)}
        :ok -> {:ok, nil}
        :error -> {:error, Error.internal("operation failed") |> maybe_add_context(opts)}
        result -> {:ok, result}
      end
    rescue
      e in Error ->
        {:error, maybe_add_context(e, opts)}

      e ->
        error = Error.from_exception(e, __STACKTRACE__)
        {:error, maybe_add_context(error, opts)}
    catch
      :exit, reason ->
        error = Error.from_exit(reason)
        {:error, maybe_add_context(error, opts)}

      :throw, value ->
        error = Error.internal("uncaught throw: #{inspect(value)}")
        {:error, maybe_add_context(error, opts)}
    end
  end

  @doc """
  Wraps a function, raising the error if it fails.

  Useful when you want to use the boundary but still raise on error.
  The difference from not using the boundary is that the error will
  be a structured `Sykli.Error` instead of whatever was raised.
  """
  def wrap!(fun, opts \\ []) when is_function(fun, 0) do
    case wrap(fun, opts) do
      {:ok, result} -> result
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc """
  Wraps multiple operations, returning all results or the first error.

  ```elixir
  Boundary.wrap_all([
    fn -> step1() end,
    fn -> step2() end,
    fn -> step3() end
  ])
  # Returns {:ok, [result1, result2, result3]} or {:error, first_error}
  ```
  """
  def wrap_all(funs, opts \\ []) when is_list(funs) do
    funs
    |> Enum.reduce_while({:ok, []}, fn fun, {:ok, acc} ->
      case wrap(fun, opts) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Runs an operation with a timeout, converting timeout to structured error.

  ```elixir
  Boundary.with_timeout(fn -> slow_operation() end, 5000,
    task: "slow_task"
  )
  ```
  """
  def with_timeout(fun, timeout_ms, opts \\ []) when is_function(fun, 0) do
    task = Task.async(fn -> wrap(fun, opts) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        task_name = Keyword.get(opts, :task, "operation")
        command = Keyword.get(opts, :command)

        error =
          if command do
            Error.task_timeout(task_name, command, timeout_ms)
          else
            Error.internal("operation timed out after #{timeout_ms}ms")
            |> Error.add_hint("increase timeout or check for blocking operations")
          end

        {:error, maybe_add_context(error, opts)}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CONTEXT HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp maybe_add_context(%Error{} = error, opts) do
    error
    |> maybe_set(:step, Keyword.get(opts, :step))
    |> maybe_set(:task, Keyword.get(opts, :task))
  end

  defp maybe_set(error, _field, nil), do: error

  defp maybe_set(%Error{} = error, :step, value) when error.step == nil do
    %{error | step: value}
  end

  defp maybe_set(%Error{} = error, :task, value) when error.task == nil do
    %{error | task: value}
  end

  defp maybe_set(error, _field, _value), do: error
end
