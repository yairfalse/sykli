defmodule Sykli.Services.CausalityService do
  @moduledoc """
  Correlates failed tasks with git changes to identify likely causes.

  Compares changed files since the last passing run against each failed task's
  declared inputs. When a changed file matches a task's input globs, that file
  is flagged as a likely cause.

  Used by both `Sykli.Occurrence.Enrichment` (full cause map for AI context)
  and `Sykli` (simplified list for run history).
  """

  alias Sykli.RunHistory

  @type cause :: %{changed_files: [String.t()], explanation: String.t()}

  @doc """
  Analyzes failed tasks and returns a map of task_name => cause.

  Each cause contains:
  - `changed_files` — files that changed AND match the task's inputs
  - `explanation` — human-readable description of the correlation

  ## Parameters

  - `failed_names` — list of failed task names
  - `graph` — the task graph (map of name => task)
  - `workdir` — project root path

  ## Options

  - `:get_field` — function to extract a field from a task struct (default: `Map.get/2`)
  """
  @spec analyze([String.t()], map(), String.t(), keyword()) :: %{String.t() => cause()}
  def analyze(failed_names, graph, workdir, opts \\ []) do
    if failed_names == [] do
      %{}
    else
      get_field = Keyword.get(opts, :get_field, &Map.get(&1, &2))
      do_analyze(failed_names, graph, workdir, get_field)
    end
  end

  @doc """
  Returns only the changed files that match a failed task's inputs.

  Convenience wrapper over `analyze/4` for callers that just need
  the file list (e.g., `Sykli.save_run_history`).
  """
  @spec changed_files_for_task(String.t(), map(), String.t()) :: [String.t()]
  def changed_files_for_task(task_name, graph, workdir) do
    case analyze([task_name], graph, workdir) do
      %{^task_name => %{changed_files: files}} -> files
      _ -> []
    end
  end

  # -- Internal --

  defp do_analyze(failed_names, graph, workdir, get_field) do
    changed_files =
      case RunHistory.load_last_good(path: workdir) do
        {:ok, last_good} -> changed_files_since(last_good.git_ref, workdir)
        _ -> MapSet.new()
      end

    if MapSet.size(changed_files) == 0 do
      Map.new(
        failed_names,
        &{&1, %{changed_files: [], explanation: "no previous good run to compare"}}
      )
    else
      Map.new(failed_names, fn name ->
        task = Map.get(graph, name, %{})
        inputs = get_field.(task, :inputs) || []

        task_files =
          inputs
          |> Enum.flat_map(fn pattern -> expand_glob(pattern, workdir) end)
          |> MapSet.new()

        matching = MapSet.intersection(changed_files, task_files) |> MapSet.to_list()

        cause =
          if matching != [] do
            %{
              changed_files: matching,
              explanation: "files matching task inputs changed since last passing run"
            }
          else
            %{
              changed_files: [],
              explanation: "no direct file match; failure may be environmental"
            }
          end

        {name, cause}
      end)
    end
  end

  defp changed_files_since(ref, workdir) do
    case Sykli.Git.run(["diff", "--name-only", ref], cd: workdir) do
      {:ok, output} -> output |> String.split("\n", trim: true) |> MapSet.new()
      _ -> MapSet.new()
    end
  end

  defp expand_glob(pattern, workdir) do
    full = Path.join(workdir, pattern)

    case Path.wildcard(full) do
      [] -> []
      files -> Enum.map(files, &Path.relative_to(&1, workdir))
    end
  end
end
