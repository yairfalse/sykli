defmodule Sykli.Fix do
  @moduledoc """
  Analyzes the latest failure and produces a "how to fix" view.

  Loads the enriched occurrence (which already contains error details,
  reasoning, causality, and history), then adds:
  - Source code lines at error locations
  - Git diff since last good run

  `sykli explain` shows what happened; `sykli fix` shows how to fix it.
  """

  alias Sykli.Git

  @default_context_lines 5
  @max_locations_per_task 5

  @doc """
  Analyze the latest occurrence and produce fix guidance.

  ## Options
    - `:task` - filter to a specific task name
    - `:context` - number of source lines around errors (default: 5)

  ## Returns
    - `{:ok, %{status: :nothing_to_fix}}` - last run passed
    - `{:ok, analysis}` - structured fix analysis
    - `{:error, :no_occurrence}` - no occurrence data found
    - `{:error, :no_failures}` - no failed tasks (after filtering)
  """
  @spec analyze(String.t(), keyword()) :: {:ok, map()} | {:error, :no_occurrence | :no_failures}
  def analyze(path, opts \\ []) do
    case load_occurrence(path) do
      nil -> {:error, :no_occurrence}
      occurrence -> analyze_occurrence(occurrence, path, opts)
    end
  end

  defp load_occurrence(path) do
    # Hot path: ETS store
    case safe_store_latest() do
      nil -> load_occurrence_cold(path)
      occ -> occ
    end
  end

  defp safe_store_latest do
    Sykli.Occurrence.Store.get_latest()
  catch
    :exit, _ -> nil
    :error, _ -> nil
  end

  defp load_occurrence_cold(path) do
    occurrence_path = Path.join([path, ".sykli", "occurrence.json"])

    case File.read(occurrence_path) do
      {:ok, json} -> Jason.decode!(json)
      {:error, _} -> nil
    end
  end

  defp analyze_occurrence(occurrence, path, opts) do
    outcome = occurrence["outcome"]

    if outcome == "success" do
      {:ok, %{status: :nothing_to_fix, run_id: occurrence["id"]}}
    else
      do_analyze(occurrence, path, opts)
    end
  end

  defp do_analyze(occurrence, path, opts) do
    task_filter = Keyword.get(opts, :task)
    context_lines = Keyword.get(opts, :context, @default_context_lines)

    data = occurrence["data"] || occurrence["ci_data"] || %{}
    tasks = data["tasks"] || []
    error_details = data["error_details"] || []
    reasoning_details = get_in(data, ["reasoning_details", "tasks"]) || %{}
    regression = data["regression"]
    last_good_ref = data["last_good_ref"]
    error_block = occurrence["error"] || %{}
    reasoning = occurrence["reasoning"] || %{}
    git = data["git"] || %{}

    # Filter to failed tasks
    failed_tasks =
      tasks
      |> Enum.filter(&(&1["status"] == "failed"))
      |> maybe_filter_task(task_filter)

    if failed_tasks == [] do
      {:error, :no_failures}
    else
      analyzed_tasks =
        Enum.map(failed_tasks, fn task ->
          analyze_task(task, error_details, reasoning_details, regression, path, context_lines)
        end)

      diff = get_diff_since_last_good(last_good_ref, path)

      summary = %{
        "run_id" => occurrence["id"],
        "timestamp" => occurrence["timestamp"],
        "failed_count" => length(failed_tasks),
        "total_count" => length(tasks),
        "git_ref" => git["sha"],
        "git_branch" => git["branch"]
      }

      {:ok,
       %{
         status: :failure_found,
         summary: summary,
         tasks: analyzed_tasks,
         diff_since_last_good: diff,
         error_summary: error_block["what_failed"],
         reasoning_summary: reasoning["summary"],
         confidence: reasoning["confidence"]
       }}
    end
  end

  defp maybe_filter_task(tasks, nil), do: tasks

  defp maybe_filter_task(tasks, filter) do
    Enum.filter(tasks, fn t -> t["name"] == filter || String.contains?(t["name"], filter) end)
  end

  defp analyze_task(task, error_details, reasoning_details, regression, path, context_lines) do
    name = task["name"]
    history = task["history"] || %{}
    error = task["error"] || %{}
    task_reasoning = Map.get(reasoning_details, name, %{})

    # Find error details for this task
    detail =
      Enum.find(error_details, fn d -> d["task"] == name end) || %{}

    raw_locations = detail["locations"] || error["locations"] || []

    # Enrich locations with source code
    locations =
      raw_locations
      |> Enum.take(@max_locations_per_task)
      |> Enum.map(fn loc -> enrich_location(loc, path, context_lines) end)

    is_regression =
      case regression do
        %{"tasks" => regression_tasks} -> name in regression_tasks
        _ -> false
      end

    %{
      "name" => name,
      "command" => task["command"],
      "exit_code" => detail["exit_code"] || error["exit_code"],
      "error_message" => error["message"],
      "locations" => locations,
      "possible_causes" => extract_causes(task_reasoning, error),
      "suggested_fix" => extract_fix(task_reasoning, error),
      "hints" => error["hints"] || [],
      "regression" => is_regression,
      "history" => normalize_history(history)
    }
  end

  # Git-correlated causes from reasoning_details take priority
  defp extract_causes(%{"changed_files" => files, "explanation" => explanation}, _error)
       when is_list(files) and files != [] do
    Enum.map(files, &"#{&1} changed") ++ [explanation]
  end

  defp extract_causes(_reasoning, %{"hints" => hints}) when is_list(hints) and hints != [],
    do: hints

  defp extract_causes(_, _), do: []

  defp extract_fix(%{"changed_files" => [file | _]}, _error),
    do: "check recent changes in #{file}"

  defp extract_fix(_reasoning, %{"hints" => [first | _]}), do: first
  defp extract_fix(_, _), do: nil

  defp normalize_history(history) when map_size(history) == 0, do: nil

  defp normalize_history(history) do
    pass_rate =
      case {history["pass_count"], history["total_count"]} do
        {p, t} when is_number(p) and is_number(t) and t > 0 -> Float.round(p / t, 2)
        _ -> nil
      end

    %{
      "pass_rate" => pass_rate,
      "streak" => history["current_streak"],
      "flaky" => history["flaky"] || false,
      "avg_duration_ms" => history["avg_duration_ms"],
      "last_failed" => history["last_failed_at"]
    }
    |> reject_nil()
  end

  defp enrich_location(loc, path, context_lines) do
    file = loc["file"]
    line = loc["line"]

    source_lines =
      if file && line do
        read_source_lines(Path.join(path, file), line, context_lines)
      else
        nil
      end

    loc
    |> Map.put("source_lines", source_lines)
  end

  @doc false
  def read_source_lines(file_path, line, context) when is_integer(line) and line > 0 do
    case File.read(file_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        total = length(lines)
        start_line = max(1, line - context)
        end_line = min(total, line + context)

        lines
        |> Enum.with_index(1)
        |> Enum.slice((start_line - 1)..(end_line - 1)//1)
        |> Enum.map(fn {text, num} ->
          prefix = if num == line, do: ">>", else: "  "
          "#{prefix} #{String.pad_leading(Integer.to_string(num), 4)} | #{text}"
        end)

      {:error, _} ->
        nil
    end
  end

  def read_source_lines(_, _, _), do: nil

  defp get_diff_since_last_good(nil, _path), do: nil

  defp get_diff_since_last_good(ref, path) do
    stat =
      case Git.run(["diff", "--stat", ref], cd: path) do
        {:ok, output} -> String.trim(output)
        _ -> nil
      end

    files =
      case Git.run(["diff", "--name-only", ref], cd: path) do
        {:ok, output} -> String.split(output, "\n", trim: true)
        _ -> []
      end

    if stat || files != [] do
      %{"ref" => ref, "files" => files, "stat" => stat}
    else
      nil
    end
  end

  defp reject_nil(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Convert analysis result to JSON-serializable map.
  """
  def to_json(%{status: :nothing_to_fix} = result) do
    %{"status" => "nothing_to_fix", "run_id" => result[:run_id]}
  end

  def to_json(%{status: :failure_found} = result) do
    %{
      "status" => "failure_found",
      "summary" => result.summary,
      "tasks" => result.tasks,
      "diff_since_last_good" => result.diff_since_last_good
    }
  end
end
