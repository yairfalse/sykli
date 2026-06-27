defmodule Sykli.Executor.Output.Sink do
  @moduledoc """
  Behaviour for executor presentation sinks.

  Register a sink with `config :sykli, :executor_output_sink, MySink`. The
  executor emits live events through `Sykli.Executor.Output`, which forwards them
  to the configured sink. **All callbacks are optional** — an event a sink does
  not implement is silently dropped — so a sink only implements the events it
  cares about. Return values are ignored.

  This is the extension point for live terminal rendering (a future
  `Sykli.CLI.Renderer`-backed sink) and the local GUI feed (see #154). There is
  no default sink: by default the executor is silent and `Sykli.CLI.Renderer`
  presents results after the run.

  ## Example

      defmodule MySink do
        @behaviour Sykli.Executor.Output.Sink

        @impl true
        def task_starting(_prefix, name, _reason), do: IO.puts("→ \#{name}")
      end
  """

  alias Sykli.Executor.TaskResult
  alias Sykli.Graph.Task

  @optional_callbacks level_header: 2,
                      task_starting: 3,
                      task_cached: 2,
                      task_skipped: 3,
                      task_failed_stopping: 1,
                      task_failed: 3,
                      task_retrying: 3,
                      run_continuing: 1,
                      gate_waiting: 3,
                      gate_approved: 3,
                      gate_denied: 3,
                      gate_timed_out: 3,
                      service_start_failed: 2,
                      missing_secrets: 2,
                      oidc_failed: 2,
                      summary: 4,
                      error: 1

  @callback level_header(level_size :: non_neg_integer(), next_tasks :: [String.t()]) :: any()
  @callback task_starting(prefix :: String.t(), name :: String.t(), reason :: String.t()) :: any()
  @callback task_cached(prefix :: String.t(), name :: String.t()) :: any()
  @callback task_skipped(prefix :: String.t(), name :: String.t(), reason :: term()) :: any()
  @callback task_failed_stopping(name :: String.t()) :: any()
  @callback task_failed(prefix :: String.t(), name :: String.t(), detail :: term()) :: any()
  @callback task_retrying(name :: String.t(), attempt :: pos_integer(), max :: pos_integer()) ::
              any()
  @callback run_continuing(failed_count :: non_neg_integer()) :: any()
  @callback gate_waiting(prefix :: String.t(), name :: String.t(), strategy :: term()) :: any()
  @callback gate_approved(prefix :: String.t(), name :: String.t(), approver :: term()) :: any()
  @callback gate_denied(prefix :: String.t(), name :: String.t(), reason :: term()) :: any()
  @callback gate_timed_out(prefix :: String.t(), name :: String.t(), timeout :: term()) :: any()
  @callback service_start_failed(name :: String.t(), reason :: term()) :: any()
  @callback missing_secrets(name :: String.t(), secrets :: [String.t()]) :: any()
  @callback oidc_failed(name :: String.t(), reason :: term()) :: any()
  @callback summary(
              results :: [TaskResult.t()],
              total_time :: non_neg_integer(),
              status :: :ok | :error,
              tasks :: [Task.t()]
            ) :: any()
  @callback error(error :: term()) :: any()
end
