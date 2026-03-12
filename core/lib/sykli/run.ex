defmodule Sykli.Run do
  @moduledoc """
  Aggregate representing a pipeline run.

  Centralizes run lifecycle state that was previously scattered across
  RunRegistry.Run, RunHistory, and Executor.Server. All state transitions
  go through this module's functions.

  ## Lifecycle

      run = Run.new(id, project_path, tasks)
      run = Run.start(run)
      run = Run.task_started(run, "test")
      run = Run.task_completed(run, "test", :passed)
      run = Run.complete(run, :ok)
  """

  @type status :: :pending | :running | :completed | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          project_path: String.t(),
          status: status(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          node: node(),
          git_ref: String.t() | nil,
          git_branch: String.t() | nil,
          tasks: %{String.t() => task_state()},
          config: map()
        }

  @type task_state :: %{
          status: :pending | :running | :passed | :failed | :cached | :skipped | :blocked,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil
        }

  defstruct [
    :id,
    :project_path,
    :started_at,
    :completed_at,
    :git_ref,
    :git_branch,
    status: :pending,
    node: nil,
    tasks: %{},
    config: %{}
  ]

  @doc "Creates a new run in :pending status."
  @spec new(String.t(), String.t(), [String.t()]) :: t()
  def new(id, project_path, task_names) do
    tasks =
      Map.new(task_names, fn name ->
        {name, %{status: :pending, started_at: nil, completed_at: nil, duration_ms: nil}}
      end)

    %__MODULE__{
      id: id,
      project_path: project_path,
      tasks: tasks,
      node: node()
    }
  end

  @doc "Transitions to :running status."
  @spec start(t()) :: t()
  def start(%__MODULE__{status: :pending} = run) do
    %{run | status: :running, started_at: DateTime.utc_now()}
  end

  @doc "Records that a task has started."
  @spec task_started(t(), String.t()) :: t()
  def task_started(%__MODULE__{} = run, task_name) do
    update_task(run, task_name, fn state ->
      %{state | status: :running, started_at: DateTime.utc_now()}
    end)
  end

  @doc "Records that a task has completed with a status."
  @spec task_completed(t(), String.t(), atom()) :: t()
  def task_completed(%__MODULE__{} = run, task_name, status) do
    now = DateTime.utc_now()

    update_task(run, task_name, fn state ->
      duration =
        if state.started_at do
          DateTime.diff(now, state.started_at, :millisecond)
        end

      %{state | status: status, completed_at: now, duration_ms: duration}
    end)
  end

  @doc "Marks the run as completed."
  @spec complete(t(), :ok | {:error, term()}) :: t()
  def complete(%__MODULE__{} = run, result) do
    status = if result == :ok, do: :completed, else: :failed
    %{run | status: status, completed_at: DateTime.utc_now()}
  end

  @doc "Returns true if the run has any failed tasks."
  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{status: :failed}), do: true

  def failed?(%__MODULE__{tasks: tasks}),
    do: Enum.any?(tasks, fn {_, t} -> t.status == :failed end)

  @doc "Returns true if the run completed successfully."
  @spec passed?(t()) :: boolean()
  def passed?(%__MODULE__{status: :completed}), do: true
  def passed?(_), do: false

  @doc "Returns total run duration in milliseconds, or nil if not completed."
  @spec duration_ms(t()) :: non_neg_integer() | nil
  def duration_ms(%__MODULE__{started_at: nil}), do: nil
  def duration_ms(%__MODULE__{completed_at: nil}), do: nil

  def duration_ms(%__MODULE__{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :millisecond)
  end

  defp update_task(%__MODULE__{} = run, task_name, fun) do
    case Map.get(run.tasks, task_name) do
      nil -> run
      state -> %{run | tasks: Map.put(run.tasks, task_name, fun.(state))}
    end
  end
end
