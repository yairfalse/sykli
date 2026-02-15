defmodule Sykli.Occurrence do
  @moduledoc """
  Generates `.sykli/occurrence.json` using the FALSE Protocol format.

  Each pipeline run produces a single occurrence with:
  - **Error block** — `what_failed`, `why_it_matters`, `possible_causes`, `suggested_fix`
  - **Reasoning block** — `summary`, `explanation`, `confidence`, `root_cause`
  - **History block** — ordered task execution steps with outcomes
  - **CI data** — domain-specific payload with task details, git context

  This is the primary AI interface. Called with raw `Executor.TaskResult` data
  (before error stringification) to preserve full `Sykli.Error` struct information.

  ## FALSE Protocol Type Hierarchy

      ci.run.passed    — all tasks succeeded
      ci.run.failed    — one or more tasks failed
      ci.task.failed   — individual task failure (per-task reasoning)
  """

  alias Sykli.ErrorContext
  alias Sykli.Executor.TaskResult
  alias Sykli.Occurrence.GitContext
  alias Sykli.Occurrence.HistoryAnalyzer
  alias Sykli.Occurrence.Store
  alias Sykli.RunHistory

  @occurrence_version "1.0"
  @max_output_lines 200

  @doc """
  Generates and writes `.sykli/occurrence.json`.

  Must be called BEFORE errors are stringified by `convert_results_to_history`.
  """
  @spec generate(map(), {:ok | :error, [TaskResult.t()]} | term(), map(), String.t()) ::
          :ok | {:error, term()}
  def generate(graph, executor_result, run_meta, workdir) do
    occurrence = build(graph, executor_result, run_meta, workdir)
    persist(occurrence, workdir)
  end

  @doc """
  Builds the occurrence map without writing to disk.
  """
  @spec build(map(), {:ok | :error, [TaskResult.t()]} | term(), map(), String.t()) :: map()
  def build(graph, executor_result, run_meta, workdir) do
    results = extract_results(executor_result)
    task_names = Enum.map(results, & &1.name)
    history_map = HistoryAnalyzer.analyze(task_names, workdir)
    {outcome, severity} = outcome_and_severity(executor_result)
    likely_causes = compute_likely_causes(results, graph, workdir)

    occurrence = %{
      "version" => @occurrence_version,
      "id" => run_meta.id,
      "timestamp" => DateTime.to_iso8601(run_meta.timestamp),
      "source" => "sykli",
      "type" => "ci.run.#{outcome}",
      "severity" => severity,
      "outcome" => outcome
    }

    occurrence
    |> maybe_add("error", build_error_block(results, graph, likely_causes, workdir))
    |> maybe_add("reasoning", build_reasoning_block(results, graph, likely_causes, workdir))
    |> Map.put("history", build_history_block(results))
    |> Map.put("ci_data", build_ci_data(results, graph, history_map, run_meta.id, workdir))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FALSE PROTOCOL: ERROR BLOCK
  # ─────────────────────────────────────────────────────────────────────────────

  # Only present when the run failed
  defp build_error_block(results, graph, likely_causes, workdir) do
    failed = Enum.filter(results, &(&1.status == :failed))

    case failed do
      [] ->
        nil

      [single] ->
        build_task_error(single, graph, likely_causes, workdir)

      multiple ->
        names = Enum.map(multiple, & &1.name)

        %{
          "code" => "ci.run.failed",
          "what_failed" => "#{length(multiple)} tasks failed: #{Enum.join(names, ", ")}",
          "why_it_matters" => build_why_it_matters(multiple, graph),
          "possible_causes" => build_possible_causes(multiple, likely_causes),
          "suggested_fix" => build_suggested_fix(multiple)
        }
        |> reject_empty()
    end
  end

  defp build_task_error(%TaskResult{} = result, graph, likely_causes, workdir) do
    task = Map.get(graph, result.name, %{})
    blocks = find_blocks(result.name, graph)

    error_map = %{
      "code" => error_code(result.error),
      "what_failed" => what_failed(result, task),
      "why_it_matters" => why_it_matters(result.name, blocks),
      "possible_causes" => build_possible_causes([result], likely_causes),
      "suggested_fix" => suggested_fix(result.error)
    }

    # Enrich with file:line locations + git context
    locations = ErrorContext.enrich(error_output(result.error), workdir)

    # Include raw output for AI consumption
    error_map
    |> maybe_add("output", truncate_output(error_output(result.error)))
    |> maybe_add("exit_code", error_exit_code(result.error))
    |> maybe_add("locations", non_empty(locations))
    |> reject_empty()
  end

  defp error_code(%Sykli.Error{code: code}), do: code
  defp error_code(:dependency_failed), do: "dependency_failed"
  defp error_code(_), do: "unknown"

  defp what_failed(%TaskResult{name: name}, task) do
    command = get_field(task, :command)
    if command, do: "task '#{name}' command: #{command}", else: "task '#{name}'"
  end

  defp why_it_matters(_task_name, blocks) do
    case blocks do
      nil -> nil
      [] -> nil
      names -> "blocks #{Enum.join(names, ", ")}"
    end
  end

  defp build_why_it_matters(failed_results, graph) do
    all_blocked =
      failed_results
      |> Enum.flat_map(fn r -> find_blocks(r.name, graph) || [] end)
      |> Enum.uniq()

    case all_blocked do
      [] -> nil
      names -> "blocks #{Enum.join(names, ", ")}"
    end
  end

  defp build_possible_causes(failed_results, likely_causes) do
    failed_results
    |> Enum.flat_map(fn r ->
      case Map.get(likely_causes, r.name) do
        %{changed_files: files} when files != [] ->
          Enum.map(files, &"#{&1} changed and matches #{r.name} inputs")

        _ ->
          error_hints(r.error)
      end
    end)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp error_hints(%Sykli.Error{hints: hints}) when is_list(hints), do: hints
  defp error_hints(_), do: []

  defp build_suggested_fix(failed_results) do
    first_fix =
      Enum.find_value(failed_results, fn r ->
        suggested_fix(r.error)
      end)

    first_fix
  end

  defp suggested_fix(%Sykli.Error{hints: [first | _]}), do: first
  defp suggested_fix(_), do: nil

  defp error_output(%Sykli.Error{output: output}), do: output
  defp error_output(_), do: nil

  defp error_exit_code(%Sykli.Error{exit_code: code}), do: code
  defp error_exit_code(_), do: nil

  # ─────────────────────────────────────────────────────────────────────────────
  # FALSE PROTOCOL: REASONING BLOCK
  # ─────────────────────────────────────────────────────────────────────────────

  # Only present when there's something to reason about (failures with causality)
  defp build_reasoning_block(results, graph, likely_causes, workdir) do
    failed = Enum.filter(results, &(&1.status == :failed))
    if failed == [], do: nil, else: do_build_reasoning(failed, graph, likely_causes, workdir)
  end

  defp do_build_reasoning(failed, _graph, likely_causes, workdir) do
    # Build per-task reasoning
    task_reasonings =
      Enum.map(failed, fn r ->
        case Map.get(likely_causes, r.name) do
          %{changed_files: files, explanation: explanation} when files != [] ->
            %{task: r.name, files: files, explanation: explanation, confidence: 0.8}

          _ ->
            %{task: r.name, files: [], explanation: "no direct file correlation", confidence: 0.2}
        end
      end)

    # Find the highest-confidence cause
    best = Enum.max_by(task_reasonings, & &1.confidence, fn -> nil end)

    summary =
      case best do
        %{files: [file | _], task: task} ->
          "#{task} failed — #{file} changed and matches task inputs"

        %{task: task} ->
          "#{task} failed — cause unclear, may be environmental"

        nil ->
          "pipeline failed"
      end

    last_good_ref =
      case RunHistory.load_last_good(path: workdir) do
        {:ok, run} -> run.git_ref
        _ -> nil
      end

    reasoning = %{
      "summary" => summary,
      "confidence" => if(best, do: best.confidence, else: 0.1)
    }

    # Per-task reasoning details
    per_task =
      Map.new(task_reasonings, fn r ->
        task_reasoning = %{
          "changed_files" => r.files,
          "explanation" => r.explanation
        }

        {r.task, task_reasoning}
      end)

    reasoning
    |> maybe_add("last_good_ref", last_good_ref)
    |> Map.put("tasks", per_task)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FALSE PROTOCOL: HISTORY BLOCK
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_history_block(results) do
    steps =
      Enum.map(results, fn %TaskResult{} = r ->
        step = %{
          "description" => r.name,
          "status" => Atom.to_string(r.status),
          "duration_ms" => r.duration_ms
        }

        # Add error summary for failed steps
        case r.error do
          %Sykli.Error{message: msg} -> Map.put(step, "error", msg)
          :dependency_failed -> Map.put(step, "error", "blocked by failed dependency")
          _ -> step
        end
      end)

    duration_ms = results |> Enum.map(& &1.duration_ms) |> Enum.sum()

    history = %{
      "steps" => steps,
      "duration_ms" => duration_ms
    }

    # Enrich with cross-run context if store is available
    case safe_store_list(20) do
      [] ->
        history

      previous_occurrences ->
        recent = build_recent_outcomes(results, previous_occurrences)
        regression = detect_regression(results, previous_occurrences)

        history
        |> maybe_add("recent_outcomes", non_empty_map(recent))
        |> maybe_add("regression", regression)
    end
  end

  defp safe_store_list(limit) do
    Store.list(limit: limit)
  catch
    :exit, _ -> []
    :error, _ -> []
  end

  defp build_recent_outcomes(results, previous_occurrences) do
    results
    |> Enum.map(fn %TaskResult{} = r ->
      outcomes =
        Enum.flat_map(previous_occurrences, fn occ ->
          tasks = get_in(occ, ["ci_data", "tasks"]) || []

          case Enum.find(tasks, &(&1["name"] == r.name)) do
            %{"status" => status} -> [normalize_task_outcome(status)]
            _ -> []
          end
        end)

      {r.name, outcomes}
    end)
    |> Enum.reject(fn {_name, outcomes} -> outcomes == [] end)
    |> Map.new()
  end

  defp detect_regression(results, previous_occurrences) do
    failed_now = Enum.filter(results, &(&1.status == :failed))
    if failed_now == [], do: nil, else: do_detect_regression(failed_now, previous_occurrences)
  end

  defp do_detect_regression(failed_now, previous_occurrences) do
    new_failures =
      Enum.filter(failed_now, fn r ->
        # Check if this task passed in all recent occurrences
        Enum.all?(previous_occurrences, fn occ ->
          tasks = get_in(occ, ["ci_data", "tasks"]) || []

          case Enum.find(tasks, &(&1["name"] == r.name)) do
            %{"status" => status} -> status in ["passed", "cached"]
            # Task didn't exist before — not a regression
            nil -> false
          end
        end)
      end)

    case new_failures do
      [] ->
        nil

      failures ->
        %{
          "is_new_failure" => true,
          "tasks" => Enum.map(failures, & &1.name)
        }
    end
  end

  defp normalize_task_outcome("passed"), do: "pass"
  defp normalize_task_outcome("cached"), do: "pass"
  defp normalize_task_outcome("failed"), do: "fail"
  defp normalize_task_outcome("skipped"), do: "skip"
  defp normalize_task_outcome("blocked"), do: "skip"
  defp normalize_task_outcome(other), do: other

  # ─────────────────────────────────────────────────────────────────────────────
  # CI DATA (Domain-Specific Payload)
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_ci_data(results, graph, history_map, run_id, workdir) do
    passed = Enum.count(results, &(&1.status in [:passed, :cached]))
    failed = Enum.count(results, &(&1.status == :failed))
    cached = Enum.count(results, &(&1.status == :cached))
    skipped = Enum.count(results, &(&1.status in [:skipped, :blocked]))

    %{
      "git" => GitContext.collect(workdir),
      "summary" => %{
        "passed" => passed,
        "failed" => failed,
        "cached" => cached,
        "skipped" => skipped
      },
      "tasks" => build_task_details(results, graph, history_map, run_id)
    }
  end

  defp build_task_details(results, graph, history_map, run_id) do
    Enum.map(results, fn %TaskResult{} = result ->
      task = Map.get(graph, result.name, %{})
      history = Map.get(history_map, result.name, %{})

      task_map = %{
        "name" => result.name,
        "status" => Atom.to_string(result.status),
        "duration_ms" => result.duration_ms,
        "cached" => result.status == :cached,
        "command" => get_field(task, :command)
      }

      task_map
      |> maybe_add("log", task_log_path(result, run_id))
      |> maybe_add("error", error_detail_map(result.error))
      |> maybe_add("covers", non_empty(get_semantic_covers(task)))
      |> maybe_add("inputs", non_empty(get_field(task, :inputs)))
      |> maybe_add("depends_on", non_empty(get_field(task, :depends_on)))
      |> maybe_add("blocks", find_blocks(result.name, graph))
      |> maybe_add("history", non_empty_map(history))
    end)
  end

  defp task_log_path(%TaskResult{output: output, name: name}, run_id)
       when is_binary(output) and output != "" do
    safe_name = String.replace(name, "/", ":")
    ".sykli/logs/#{run_id}/#{safe_name}.log"
  end

  defp task_log_path(_result, _run_id), do: nil

  @doc """
  Converts a `Sykli.Error` struct to a detailed map for per-task error info.

  Preserves all structured data including output, exit_code, hints, notes.
  """
  @spec error_detail_map(term()) :: map() | nil
  def error_detail_map(nil), do: nil

  def error_detail_map(%Sykli.Error{} = e) do
    locations =
      e.locations
      |> Enum.map(fn loc ->
        %{"file" => loc.file, "line" => loc.line}
        |> maybe_add("column", loc.column)
        |> maybe_add("message", loc.message)
      end)

    %{
      "code" => e.code,
      "message" => e.message,
      "exit_code" => e.exit_code,
      "output" => truncate_output(e.output),
      "hints" => e.hints,
      "notes" => e.notes
    }
    |> maybe_add("locations", non_empty(locations))
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == [] end)
    |> Map.new()
  end

  def error_detail_map(:dependency_failed) do
    %{"code" => "dependency_failed", "message" => "blocked by failed dependency"}
  end

  def error_detail_map(other) do
    %{"message" => inspect(other)}
  end

  # Keep backward compat for tests
  defdelegate error_to_map(error), to: __MODULE__, as: :error_detail_map

  # ─────────────────────────────────────────────────────────────────────────────
  # CAUSALITY (internal — feeds into reasoning block)
  # ─────────────────────────────────────────────────────────────────────────────

  defp compute_likely_causes(results, graph, workdir) do
    failed =
      results
      |> Enum.filter(&(&1.status == :failed))
      |> Enum.map(& &1.name)

    if failed == [] do
      %{}
    else
      changed_files =
        case RunHistory.load_last_good(path: workdir) do
          {:ok, last_good} -> changed_files_since(last_good.git_ref, workdir)
          _ -> MapSet.new()
        end

      if MapSet.size(changed_files) == 0 do
        Map.new(
          failed,
          &{&1, %{changed_files: [], explanation: "no previous good run to compare"}}
        )
      else
        Map.new(failed, fn name ->
          task = Map.get(graph, name, %{})
          inputs = get_field(task, :inputs) || []

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
  end

  defp changed_files_since(ref, workdir) do
    case Sykli.Git.run(["diff", "--name-only", ref], cd: workdir) do
      {:ok, output} ->
        output |> String.split("\n", trim: true) |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp expand_glob(pattern, workdir) do
    full = Path.join(workdir, pattern)

    case Path.wildcard(full) do
      [] -> []
      files -> Enum.map(files, &Path.relative_to(&1, workdir))
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp outcome_and_severity(executor_result) do
    case executor_result do
      {:ok, _} -> {"passed", "info"}
      {:error, _} -> {"failed", "error"}
      _ -> {"failed", "error"}
    end
  end

  defp extract_results({:ok, results}) when is_list(results), do: results
  defp extract_results({:error, results}) when is_list(results), do: results
  defp extract_results(_), do: []

  defp get_field(%{} = task, field), do: Map.get(task, field)

  defp get_semantic_covers(%{semantic: %{covers: covers}}) when is_list(covers), do: covers
  defp get_semantic_covers(_), do: nil

  defp find_blocks(task_name, graph) do
    blocks =
      graph
      |> Enum.filter(fn {_name, task} ->
        deps = Map.get(task, :depends_on) || []
        task_name in deps
      end)
      |> Enum.map(fn {name, _task} -> name end)

    non_empty(blocks)
  end

  defp truncate_output(nil), do: nil

  defp truncate_output(output) when is_binary(output) do
    lines = String.split(output, "\n")

    if length(lines) > @max_output_lines do
      truncated = Enum.take(lines, @max_output_lines)
      remaining = length(lines) - @max_output_lines
      Enum.join(truncated, "\n") <> "\n... (#{remaining} more lines)"
    else
      output
    end
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp non_empty(nil), do: nil
  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp non_empty_map(nil), do: nil
  defp non_empty_map(map) when map == %{}, do: nil
  defp non_empty_map(map), do: map

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == [] end)
    |> Map.new()
  end

  defp persist(occurrence, workdir) do
    dir = Path.join(workdir, ".sykli")

    with :ok <- File.mkdir_p(dir) do
      # 1. JSON — cold path for AI/external consumers
      json_path = Path.join(dir, "occurrence.json")
      json = Jason.encode!(occurrence, pretty: true)
      :ok = File.write(json_path, json)

      # 2. ETF — warm path for fast sykli reload
      etf_dir = Path.join(dir, "occurrences")
      File.mkdir_p!(etf_dir)
      filename = "#{occurrence["id"]}.etf"
      etf_path = Path.join(etf_dir, filename)
      File.write!(etf_path, :erlang.term_to_binary(occurrence))

      # 3. ETS — hot path if store is running
      safe_store_put(occurrence)

      # 4. Evict old .etf files (keep last 50)
      evict_old_etf(etf_dir, 50)

      :ok
    end
  end

  defp safe_store_put(occurrence) do
    Store.put(occurrence)
  catch
    :exit, _ -> :ok
    :error, _ -> :ok
  end

  defp evict_old_etf(etf_dir, max) do
    case File.ls(etf_dir) do
      {:ok, files} ->
        etf_files =
          files
          |> Enum.filter(&String.ends_with?(&1, ".etf"))
          |> Enum.sort_by(fn file ->
            path = Path.join(etf_dir, file)

            case File.stat(path) do
              {:ok, %File.Stat{mtime: mtime}} -> mtime
              _ -> {{1970, 1, 1}, {0, 0, 0}}
            end
          end)

        if length(etf_files) > max do
          etf_files
          |> Enum.take(length(etf_files) - max)
          |> Enum.each(fn file ->
            File.rm(Path.join(etf_dir, file))
          end)
        end

      {:error, _} ->
        :ok
    end
  end
end
