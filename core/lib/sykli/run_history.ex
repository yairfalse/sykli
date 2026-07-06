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
  @default_max_runs 100

  # ----- STRUCTS -----

  defmodule TaskResult do
    @moduledoc "Result of a single task execution"

    @enforce_keys [:name, :status, :duration_ms]
    defstruct [
      :name,
      :status,
      :duration_ms,
      :error,
      :kind,
      :review_result,
      :failure_semantics,
      :mandate_outcome,
      :contract_slice,
      :inputs,
      :likely_cause,
      :verified_on,
      success_criteria_results: [],
      evidence_results: [],
      cached: false,
      streak: 0
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            status: :passed | :failed | :skipped,
            duration_ms: non_neg_integer(),
            cached: boolean(),
            error: String.t() | nil,
            kind: String.t() | nil,
            review_result: map() | nil,
            failure_semantics: Sykli.FailureSemantics.t() | nil,
            mandate_outcome: map() | nil,
            contract_slice: map() | nil,
            success_criteria_results: [Sykli.SuccessCriteria.Result.t() | map()] | nil,
            evidence_results: [Sykli.EvidenceRequirement.Result.t()],
            inputs: [String.t()] | nil,
            likely_cause: [String.t()] | nil,
            verified_on: String.t() | nil,
            streak: non_neg_integer()
          }
  end

  defmodule Run do
    @moduledoc "A complete run manifest"

    @enforce_keys [:id, :timestamp, :git_ref, :git_branch, :tasks, :overall]
    defstruct [
      :id,
      :timestamp,
      :git_ref,
      :git_branch,
      :tasks,
      :overall,
      :work_item_id,
      :contract_hash,
      :platform,
      :verification,
      verified: false
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            timestamp: DateTime.t(),
            git_ref: String.t(),
            git_branch: String.t(),
            tasks: [Sykli.RunHistory.TaskResult.t()],
            overall: :passed | :failed,
            work_item_id: String.t() | nil,
            contract_hash: String.t() | nil,
            platform: String.t() | nil,
            verified: boolean(),
            verification: map() | nil
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

    # Prune old runs
    prune(runs_dir, opts)

    :ok
  end

  @doc """
  Prune old run files beyond the maximum limit.

  Configurable via `SYKLI_MAX_RUNS` env var (default: #{@default_max_runs}).
  Preserves symlinks (latest.json, last_good.json).
  """
  @spec prune(String.t(), keyword()) :: :ok
  def prune(runs_dir, opts \\ []) do
    max_runs =
      Keyword.get_lazy(opts, :max_runs, fn ->
        case System.get_env("SYKLI_MAX_RUNS") do
          nil ->
            @default_max_runs

          val ->
            case Integer.parse(val) do
              {int, ""} when int > 0 -> int
              _ -> @default_max_runs
            end
        end
      end)

    case File.ls(runs_dir) do
      {:ok, files} ->
        # Only timestamp-based JSON files (not symlinks like latest.json, last_good.json)
        run_files =
          files
          |> Enum.filter(&String.match?(&1, ~r/^\d{4}-\d{2}-\d{2}.*\.json$/))
          |> Enum.sort()

        if length(run_files) > max_runs do
          excess = Enum.take(run_files, length(run_files) - max_runs)

          Enum.each(excess, fn file ->
            File.rm(Path.join(runs_dir, file))
          end)
        end

        :ok

      {:error, _} ->
        :ok
    end
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
          |> maybe_take(limit)
          |> Enum.flat_map(fn file ->
            case File.read(Path.join(runs_dir, file)) do
              {:ok, json} -> [decode_run(json)]
              {:error, _} -> []
            end
          end)

        {:ok, runs}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists recent runs associated with a local work item.

  Filtering happens before applying `:limit`, so unrelated recent runs do not
  hide older runs for the requested work item. Pagination is not implemented
  yet; this scans local run manifests.
  """
  @spec list_by_work_item(String.t(), keyword()) :: {:ok, [Run.t()]} | {:error, term()}
  def list_by_work_item(work_item_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    list_opts = Keyword.put(opts, :limit, :all)

    with :ok <- Sykli.WorkItem.validate_id(work_item_id),
         {:ok, runs} <- list(list_opts) do
      runs =
        runs
        |> Enum.filter(&(&1.work_item_id == work_item_id))
        |> maybe_take(limit)

      {:ok, runs}
    end
  end

  # ----- PRIVATE -----

  defp maybe_take(items, :all), do: items
  defp maybe_take(items, limit), do: Enum.take(items, limit)

  defp timestamp_to_filename(%DateTime{} = dt) do
    dt
    |> DateTime.to_iso8601()
    |> String.replace(":", "-")
    |> Kernel.<>(".json")
  end

  defp update_symlink(runs_dir, target, link_name) do
    link_path = Path.join(runs_dir, link_name)
    temp_link = link_path <> ".new.#{:rand.uniform(100_000)}"

    # Atomic symlink update: create new link, then rename over old one
    # This avoids a window where the symlink doesn't exist
    case File.ln_s(target, temp_link) do
      :ok ->
        case File.rename(temp_link, link_path) do
          :ok ->
            :ok

          {:error, _} = error ->
            File.rm(temp_link)
            error
        end

      {:error, _} = error ->
        error
    end
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
    |> maybe_add(:work_item_id, run.work_item_id)
    |> maybe_add(:contract_hash, run.contract_hash)
    |> maybe_add(:platform, run.platform)
    |> maybe_add(:verified, if(run.verified, do: true, else: nil))
    |> maybe_add(:verification, run.verification)
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
    |> maybe_add(:kind, tr.kind)
    |> maybe_add(:review_result, tr.review_result)
    |> maybe_add(:failure_semantics, Sykli.FailureSemantics.to_map(tr.failure_semantics))
    |> maybe_add(:mandate_outcome, tr.mandate_outcome)
    |> maybe_add(:contract_slice, tr.contract_slice)
    |> maybe_add(
      :success_criteria_results,
      non_empty_success_criteria_results(tr.success_criteria_results)
    )
    |> maybe_add(:evidence_results, non_empty_evidence_results(tr.evidence_results))
    |> maybe_add(:inputs, tr.inputs)
    |> maybe_add(:likely_cause, tr.likely_cause)
    |> maybe_add(:verified_on, tr.verified_on)
  end

  defp non_empty_success_criteria_results(nil), do: nil
  defp non_empty_success_criteria_results([]), do: nil

  defp non_empty_success_criteria_results(results),
    do: Sykli.ContractSlice.success_criteria_results(results)

  defp non_empty_evidence_results(nil), do: nil
  defp non_empty_evidence_results([]), do: nil
  defp non_empty_evidence_results(results), do: Sykli.ContractSlice.evidence_results(results)

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
      overall: String.to_existing_atom(data["overall"]),
      work_item_id: data["work_item_id"],
      contract_hash: data["contract_hash"],
      platform: data["platform"],
      verified: data["verified"] || false,
      verification: data["verification"]
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
      kind: data["kind"],
      review_result: data["review_result"],
      failure_semantics: Sykli.FailureSemantics.from_map(data["failure_semantics"]),
      mandate_outcome: data["mandate_outcome"],
      contract_slice: data["contract_slice"],
      success_criteria_results:
        Sykli.ContractSlice.success_criteria_results_from_maps(data["success_criteria_results"]),
      evidence_results: Sykli.ContractSlice.evidence_results_from_maps(data["evidence_results"]),
      inputs: data["inputs"],
      likely_cause: data["likely_cause"],
      verified_on: data["verified_on"]
    }
  end

  defp parse_timestamp(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> DateTime.utc_now()
    end
  end
end
