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
      ci.task.cached       — task skipped due to cache hit
      ci.task.skipped      — task skipped (condition not met or dependency failed)
      ci.task.retrying     — task failed, retrying
      ci.task.output       — task produced output
      ci.cache.miss        — cache miss with reason
      ci.gate.waiting      — gate awaiting approval
      ci.gate.resolved     — gate approved/denied/timed out

  ## Enrichment

  Lightweight events have nil blocks. Terminal events get enriched:

      occ = Occurrence.run_completed(run_id, result)
      occ = Enrichment.enrich(occ, graph, results, workdir)
      # → rich occurrence with error, reasoning, history, data
  """

  alias Sykli.Occurrence.{
    RunStarted,
    RunCompleted,
    TaskStarted,
    TaskCompleted,
    TaskOutput,
    TaskCached,
    TaskSkipped,
    TaskRetrying,
    CacheMiss,
    GateWaiting,
    GateResolved
  }

  @occurrence_version "1.0"

  @type severity :: :info | :warning | :error | :critical
  @type t :: %__MODULE__{
          id: String.t(),
          timestamp: DateTime.t(),
          protocol_version: String.t(),
          type: String.t(),
          source: String.t(),
          severity: severity(),
          outcome: String.t() | nil,
          run_id: String.t(),
          node: atom() | nil,
          context: map(),
          data: struct() | map() | nil,
          error: map() | nil,
          reasoning: map() | nil,
          history: map() | nil
        }

  defstruct [
    :id,
    :timestamp,
    :protocol_version,
    :type,
    :source,
    :severity,
    :outcome,
    :run_id,
    :node,
    :data,
    :error,
    :reasoning,
    :history,
    context: %{}
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

  @doc "Create a ci.task.cached occurrence."
  @spec task_cached(String.t(), String.t(), String.t() | nil, keyword()) :: t()
  def task_cached(run_id, task_name, cache_key \\ nil, opts \\ []) do
    new("ci.task.cached", run_id, TaskCached.new(task_name, cache_key),
      severity: :info,
      opts: opts
    )
  end

  @doc "Create a ci.task.skipped occurrence."
  @spec task_skipped(String.t(), String.t(), TaskSkipped.reason(), keyword()) :: t()
  def task_skipped(run_id, task_name, reason, opts \\ []) do
    new("ci.task.skipped", run_id, TaskSkipped.new(task_name, reason),
      severity: :info,
      opts: opts
    )
  end

  @doc "Create a ci.task.retrying occurrence."
  @spec task_retrying(String.t(), String.t(), pos_integer(), pos_integer(), keyword()) :: t()
  def task_retrying(run_id, task_name, attempt, max_attempts, opts \\ []) do
    new("ci.task.retrying", run_id, TaskRetrying.new(task_name, attempt, max_attempts),
      severity: :warning,
      opts: opts
    )
  end

  @doc "Create a ci.cache.miss occurrence."
  @spec cache_miss(String.t(), String.t(), String.t() | nil, String.t() | nil, keyword()) :: t()
  def cache_miss(run_id, task_name, cache_key \\ nil, reason \\ nil, opts \\ []) do
    new("ci.cache.miss", run_id, CacheMiss.new(task_name, cache_key, reason),
      severity: :info,
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

    context =
      %{}
      |> maybe_put("trace_id", opts[:trace_id])
      |> maybe_put("span_id", opts[:span_id])

    %__MODULE__{
      id: Sykli.ULID.generate(),
      timestamp: opts[:timestamp] || DateTime.utc_now(),
      protocol_version: @occurrence_version,
      type: type,
      source: "sykli",
      severity: Keyword.get(kw, :severity, :info),
      outcome: Keyword.get(kw, :outcome),
      run_id: run_id,
      node: node(),
      context: context,
      data: data
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp run_completed_fields(:success), do: {"ci.run.passed", :info, "success"}
  defp run_completed_fields(:failure), do: {"ci.run.failed", :error, "failure"}
end
