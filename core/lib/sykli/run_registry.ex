defmodule Sykli.RunRegistry do
  @moduledoc """
  Registry for tracking sykli runs with unique IDs.

  Each run gets a unique ID and is tracked with its metadata.
  Uses ETS for fast reads from any process.

  ## Example

      # Start a new run
      {:ok, run_id} = Sykli.RunRegistry.start_run("/path/to/project", tasks)

      # Get run info
      {:ok, run} = Sykli.RunRegistry.get_run(run_id)

      # Update status
      Sykli.RunRegistry.update_status(run_id, :running)

      # Complete a run
      Sykli.RunRegistry.complete_run(run_id, :ok)

      # List all runs
      runs = Sykli.RunRegistry.list_runs()
  """

  use GenServer

  @table :sykli_runs

  # Run struct
  defmodule Run do
    @moduledoc false
    defstruct [
      :id,
      :project_path,
      :tasks,
      :status,          # :pending | :running | :completed | :failed
      :result,          # nil | :ok | {:error, reason}
      :started_at,
      :completed_at,
      :node
    ]
  end

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start tracking a new run. Returns `{:ok, run_id}`.
  """
  def start_run(project_path, tasks) do
    GenServer.call(__MODULE__, {:start_run, project_path, tasks})
  end

  @doc """
  Get a run by ID. Returns `{:ok, run}` or `{:error, :not_found}`.
  """
  def get_run(run_id) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] -> {:ok, run}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Update the status of a run.
  """
  def update_status(run_id, status) do
    GenServer.call(__MODULE__, {:update_status, run_id, status})
  end

  @doc """
  Mark a run as completed with a result.
  """
  def complete_run(run_id, result) do
    GenServer.call(__MODULE__, {:complete_run, run_id, result})
  end

  @doc """
  List all runs, optionally filtered by status.

  Options:
    * `:status` - Filter by status (:pending, :running, :completed, :failed)
    * `:limit` - Maximum number of runs to return
  """
  def list_runs(opts \\ []) do
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit)

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, run} -> run end)
    |> filter_by_status(status)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
    |> maybe_limit(limit)
  end

  @doc """
  List runs currently in progress.
  """
  def active_runs do
    list_runs(status: :running)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:start_run, project_path, tasks}, _from, state) do
    run_id = generate_id()
    now = DateTime.utc_now()

    run = %Run{
      id: run_id,
      project_path: project_path,
      tasks: tasks,
      status: :pending,
      result: nil,
      started_at: now,
      completed_at: nil,
      node: node()
    }

    :ets.insert(@table, {run_id, run})
    {:reply, {:ok, run_id}, state}
  end

  @impl true
  def handle_call({:update_status, run_id, status}, _from, state) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] ->
        updated = %{run | status: status}
        :ets.insert(@table, {run_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:complete_run, run_id, result}, _from, state) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] ->
        status = if result == :ok, do: :completed, else: :failed
        updated = %{run |
          status: status,
          result: result,
          completed_at: DateTime.utc_now()
        }
        :ets.insert(@table, {run_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  ## Private Functions

  defp generate_id do
    # Short readable ID: timestamp + random suffix
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "run_#{timestamp}_#{suffix}"
  end

  defp filter_by_status(runs, nil), do: runs
  defp filter_by_status(runs, status), do: Enum.filter(runs, &(&1.status == status))

  defp maybe_limit(runs, nil), do: runs
  defp maybe_limit(runs, limit), do: Enum.take(runs, limit)
end
