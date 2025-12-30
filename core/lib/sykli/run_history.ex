defmodule Sykli.RunHistory do
  @moduledoc """
  Stores and retrieves run history for observability.

  Every sykli run saves a manifest to `.sykli/runs/` containing:
  - Task results (pass/fail, duration, cached)
  - Git context (ref, branch)
  - Timestamps for historical tracking

  Provides:
  - Latest run and "last known good" quick access
  - Task streak calculation (consecutive passes)
  - Failure correlation (likely cause detection)
  """

  @runs_dir ".sykli/runs"

  # ----- STRUCTS -----

  defmodule TaskResult do
    @moduledoc "Result of a single task execution"

    @enforce_keys [:name, :status, :duration_ms]
    defstruct [
      :name,
      :status,
      :duration_ms,
      :error,
      :inputs,
      :likely_cause,
      cached: false,
      streak: 0
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            status: :passed | :failed | :skipped,
            duration_ms: non_neg_integer(),
            cached: boolean(),
            error: String.t() | nil,
            inputs: [String.t()] | nil,
            likely_cause: [String.t()] | nil,
            streak: non_neg_integer()
          }
  end

  defmodule Run do
    @moduledoc "A complete run manifest"

    @enforce_keys [:id, :timestamp, :git_ref, :git_branch, :tasks, :overall]
    defstruct [:id, :timestamp, :git_ref, :git_branch, :tasks, :overall]

    @type t :: %__MODULE__{
            id: String.t(),
            timestamp: DateTime.t(),
            git_ref: String.t(),
            git_branch: String.t(),
            tasks: [Sykli.RunHistory.TaskResult.t()],
            overall: :passed | :failed
          }
  end

  # ----- PUBLIC API -----

  @doc """
  Save a run manifest to disk.

  Creates:
  - `{timestamp}.json` - the run file
  - `latest.json` - symlink to most recent
  - `last_good.json` - symlink to most recent passing run (if applicable)
  """
  @spec save(Run.t(), keyword()) :: :ok | {:error, term()}
  def save(%Run{} = run, opts \\ []) do
    base_path = Keyword.get(opts, :path, ".")
    runs_dir = Path.join(base_path, @runs_dir)

    # Ensure directory exists
    File.mkdir_p!(runs_dir)

    # Generate filename from timestamp
    filename = timestamp_to_filename(run.timestamp)
    file_path = Path.join(runs_dir, filename)

    # Serialize and write
    json = encode_run(run)
    File.write!(file_path, json)

    # Update latest symlink
    update_symlink(runs_dir, filename, "latest.json")

    # Update last_good if all passed
    if run.overall == :passed do
      update_symlink(runs_dir, filename, "last_good.json")
    end

    :ok
  end

  @doc """
  Load the most recent run.
  """
  @spec load_latest(keyword()) :: {:ok, Run.t()} | {:error, :no_runs}
  def load_latest(opts \\ []) do
    base_path = Keyword.get(opts, :path, ".")
    latest_path = Path.join([base_path, @runs_dir, "latest.json"])

    case File.read(latest_path) do
      {:ok, json} -> {:ok, decode_run(json)}
      {:error, :enoent} -> {:error, :no_runs}
    end
  end

  @doc """
  Load the most recent passing run.
  """
  @spec load_last_good(keyword()) :: {:ok, Run.t()} | {:error, :no_passing_runs}
  def load_last_good(opts \\ []) do
    base_path = Keyword.get(opts, :path, ".")
    last_good_path = Path.join([base_path, @runs_dir, "last_good.json"])

    case File.read(last_good_path) do
      {:ok, json} -> {:ok, decode_run(json)}
      {:error, :enoent} -> {:error, :no_passing_runs}
    end
  end

  @doc """
  List recent runs in reverse chronological order.
  """
  @spec list(keyword()) :: {:ok, [Run.t()]} | {:error, term()}
  def list(opts \\ []) do
    base_path = Keyword.get(opts, :path, ".")
    limit = Keyword.get(opts, :limit, 10)
    runs_dir = Path.join(base_path, @runs_dir)

    case File.ls(runs_dir) do
      {:ok, files} ->
        runs =
          files
          # Only .json files, not symlinks
          |> Enum.filter(&String.match?(&1, ~r/^\d{4}-\d{2}-\d{2}.*\.json$/))
          |> Enum.sort(:desc)
          |> Enum.take(limit)
          |> Enum.flat_map(fn file ->
            case File.read(Path.join(runs_dir, file)) do
              {:ok, json} -> [decode_run(json)]
              {:error, _} -> []
            end
          end)

        {:ok, runs}

      {:error, :enoent} ->
        {:ok, []}
    end
  end

  @doc """
  Calculate the current streak (consecutive passes) for a task.
  """
  @spec calculate_streak(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def calculate_streak(task_name, opts \\ []) do
    case list(opts) do
      {:ok, runs} ->
        streak = count_streak(runs, task_name)
        {:ok, streak}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Calculate likely cause by intersecting changed files with task inputs.
  """
  @spec likely_cause(MapSet.t(), MapSet.t()) :: MapSet.t()
  def likely_cause(changed_files, task_inputs) do
    MapSet.intersection(changed_files, task_inputs)
  end

  # ----- PRIVATE -----

  defp timestamp_to_filename(%DateTime{} = dt) do
    dt
    |> DateTime.to_iso8601()
    |> String.replace(":", "-")
    |> Kernel.<>(".json")
  end

  defp update_symlink(runs_dir, target, link_name) do
    link_path = Path.join(runs_dir, link_name)

    # Remove existing symlink if present
    File.rm(link_path)

    # Create new symlink (use relative path)
    File.ln_s(target, link_path)
  end

  defp encode_run(%Run{} = run) do
    %{
      id: run.id,
      timestamp: DateTime.to_iso8601(run.timestamp),
      git_ref: run.git_ref,
      git_branch: run.git_branch,
      tasks: Enum.map(run.tasks, &encode_task_result/1),
      overall: Atom.to_string(run.overall)
    }
    |> Jason.encode!(pretty: true)
  end

  defp encode_task_result(%TaskResult{} = tr) do
    %{
      name: tr.name,
      status: Atom.to_string(tr.status),
      duration_ms: tr.duration_ms,
      cached: tr.cached,
      streak: tr.streak
    }
    |> maybe_add(:error, tr.error)
    |> maybe_add(:inputs, tr.inputs)
    |> maybe_add(:likely_cause, tr.likely_cause)
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp decode_run(json) do
    data = Jason.decode!(json)

    %Run{
      id: data["id"],
      timestamp: parse_timestamp(data["timestamp"]),
      git_ref: data["git_ref"],
      git_branch: data["git_branch"],
      tasks: Enum.map(data["tasks"] || [], &decode_task_result/1),
      overall: String.to_existing_atom(data["overall"])
    }
  end

  defp decode_task_result(data) do
    %TaskResult{
      name: data["name"],
      status: String.to_existing_atom(data["status"]),
      duration_ms: data["duration_ms"],
      cached: data["cached"] || false,
      streak: data["streak"] || 0,
      error: data["error"],
      inputs: data["inputs"],
      likely_cause: data["likely_cause"]
    }
  end

  defp parse_timestamp(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp count_streak(runs, task_name) do
    runs
    |> Enum.reduce_while(0, fn run, count ->
      task_result = Enum.find(run.tasks, &(&1.name == task_name))

      case task_result do
        nil -> {:halt, count}
        %{status: :passed} -> {:cont, count + 1}
        _ -> {:halt, count}
      end
    end)
  end
end
