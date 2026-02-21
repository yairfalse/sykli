defmodule Sykli.Occurrence do
  @moduledoc """
  The unified event struct for Sykli — events ARE occurrences from birth.

  Replaces the dual `Sykli.Events.Event` + `Sykli.Occurrence` system.
  Every internal pub/sub message is a FALSE Protocol occurrence, with
  lightweight events carrying nil blocks and terminal events enriched
  with error/reasoning/history/ci_data.

  ## FALSE Protocol Types

      ci.run.started       — pipeline run begins
      ci.run.passed        — all tasks succeeded
      ci.run.failed        — one or more tasks failed
      ci.task.started      — task begins execution
      ci.task.completed    — task finished (success or failure)
      ci.task.output       — task produced output
      ci.gate.waiting      — gate awaiting approval
      ci.gate.resolved     — gate approved/denied/timed out

  ## Enrichment

  Lightweight events have nil blocks. Terminal events get enriched:

      occ = Occurrence.run_completed(run_id, result)
      occ = Enrichment.enrich(occ, graph, results, workdir)
      # → rich occurrence with error, reasoning, history, ci_data
  """

  alias Sykli.Occurrence.{
    RunStarted,
    RunCompleted,
    TaskStarted,
    TaskCompleted,
    TaskOutput,
    GateWaiting,
    GateResolved
  }

  @occurrence_version "1.0"

  @type severity :: :info | :warning | :error | :critical
  @type t :: %__MODULE__{
          id: String.t(),
          timestamp: DateTime.t(),
          version: String.t(),
          type: String.t(),
          source: String.t(),
          severity: severity(),
          outcome: String.t() | nil,
          run_id: String.t(),
          node: atom() | nil,
          trace_id: String.t() | nil,
          span_id: String.t() | nil,
          parent_span_id: String.t() | nil,
          duration_us: non_neg_integer() | nil,
          data: struct() | map() | nil,
          error: map() | nil,
          reasoning: map() | nil,
          history: map() | nil,
          ci_data: map() | nil
        }

  defstruct [
    :id,
    :timestamp,
    :version,
    :type,
    :source,
    :severity,
    :outcome,
    :run_id,
    :node,
    :trace_id,
    :span_id,
    :parent_span_id,
    :duration_us,
    :data,
    :error,
    :reasoning,
    :history,
    :ci_data
  ]

  # ─────────────────────────────────────────────────────────────────────────────
  # FACTORY FUNCTIONS
  # ─────────────────────────────────────────────────────────────────────────────

  @doc "Create a ci.run.started occurrence."
  @spec run_started(String.t(), String.t(), [String.t()], keyword()) :: t()
  def run_started(run_id, project_path, tasks, opts \\ []) do
    new("ci.run.started", run_id, RunStarted.new(project_path, tasks),
      severity: :info,
      opts: opts
    )
  end

  @doc "Create a ci.task.started occurrence."
  @spec task_started(String.t(), String.t(), keyword()) :: t()
  def task_started(run_id, task_name, opts \\ []) do
    new("ci.task.started", run_id, TaskStarted.new(task_name),
      severity: :info,
      opts: opts
    )
  end

  @doc "Create a ci.task.output occurrence."
  @spec task_output(String.t(), String.t(), String.t(), keyword()) :: t()
  def task_output(run_id, task_name, output, opts \\ []) do
    new("ci.task.output", run_id, TaskOutput.new(task_name, output),
      severity: :info,
      opts: opts
    )
  end

  @doc "Create a ci.task.completed occurrence."
  @spec task_completed(String.t(), String.t(), :ok | {:error, term()}, keyword()) :: t()
  def task_completed(run_id, task_name, result, opts \\ []) do
    data = TaskCompleted.from_result(task_name, result, nil)
    severity = if data.outcome == :failure, do: :error, else: :info

    new("ci.task.completed", run_id, data,
      severity: severity,
      opts: opts
    )
  end

  @doc """
  Create a ci.run.passed or ci.run.failed occurrence.

  The type is determined by the result: `:ok` → `ci.run.passed`, `{:error, _}` → `ci.run.failed`.
  """
  @spec run_completed(String.t(), :ok | {:error, term()}, keyword()) :: t()
  def run_completed(run_id, result, opts \\ []) do
    data = RunCompleted.from_result(result)
    {type, severity, outcome} = run_completed_fields(data.outcome)

    new(type, run_id, data,
      severity: severity,
      outcome: outcome,
      opts: opts
    )
  end

  @doc "Create a ci.gate.waiting occurrence."
  @spec gate_waiting(String.t(), String.t(), atom(), String.t() | nil, pos_integer(), keyword()) ::
          t()
  def gate_waiting(run_id, gate_name, strategy, message, timeout, opts \\ []) do
    new("ci.gate.waiting", run_id, GateWaiting.new(gate_name, strategy, message, timeout),
      severity: :info,
      opts: opts
    )
  end

  @doc "Create a ci.gate.resolved occurrence."
  @spec gate_resolved(
          String.t(),
          String.t(),
          atom(),
          String.t() | nil,
          non_neg_integer(),
          keyword()
        ) :: t()
  def gate_resolved(run_id, gate_name, outcome, approver, duration_ms, opts \\ []) do
    severity = if outcome == :denied || outcome == :timed_out, do: :warning, else: :info

    new("ci.gate.resolved", run_id, GateResolved.new(gate_name, outcome, approver, duration_ms),
      severity: severity,
      opts: opts
    )
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # INTERNAL
  # ─────────────────────────────────────────────────────────────────────────────

  defp new(type, run_id, data, kw) do
    opts = Keyword.get(kw, :opts, [])

    %__MODULE__{
      id: Sykli.ULID.generate(),
      timestamp: opts[:timestamp] || DateTime.utc_now(),
      version: @occurrence_version,
      type: type,
      source: "sykli",
      severity: Keyword.get(kw, :severity, :info),
      outcome: Keyword.get(kw, :outcome),
      run_id: run_id,
      node: node(),
      data: data,
      trace_id: opts[:trace_id],
      span_id: opts[:span_id],
      parent_span_id: opts[:parent_span_id],
      duration_us: opts[:duration_us]
    }
  end

  defp run_completed_fields(:success), do: {"ci.run.passed", :info, "passed"}
  defp run_completed_fields(:failure), do: {"ci.run.failed", :error, "failed"}
end
