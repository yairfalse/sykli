defmodule Sykli.Occurrence.Enrichment do
  @moduledoc """
  Enriches a terminal occurrence with FALSE Protocol blocks.

  Called once at the end of a pipeline run to populate:
  - **error** — code, what_failed, why_it_matters, possible_causes, suggested_fix
  - **reasoning** — summary, explanation, confidence
  - **history** — ordered steps with timestamps, actions, outcomes
  - **data** — git context, task details, summary counts (domain-specific payload)
  """

  alias Sykli.ErrorContext
  alias Sykli.Executor.TaskResult
  alias Sykli.Occurrence
  alias Sykli.Occurrence.GitContext
  alias Sykli.Occurrence.HistoryAnalyzer
  alias Sykli.Occurrence.Store
  alias Sykli.RunHistory
  alias Sykli.Services.CausalityService

  @max_output_lines 200

  @doc """
  Enriches a terminal occurrence (ci.run.passed / ci.run.failed) with
  error, reasoning, history, and ci_data blocks.

  Also persists the enriched occurrence to JSON, ETF, and ETS.
  """
  @spec enrich_and_persist(
          Occurrence.t(),
          map(),
          {:ok | :error, [TaskResult.t()]} | term(),
          String.t()
        ) ::
          :ok | {:error, term()}
  def enrich_and_persist(%Occurrence{} = occ, graph, executor_result, workdir) do
    enriched = enrich(occ, graph, executor_result, workdir)
    result = persist(enriched, workdir)

    # Generate SLSA provenance attestation for terminal events
    if occ.type in ["ci.run.passed", "ci.run.failed"] do
      persist_attestation(enriched, graph, workdir)
    end

    # Fire-and-forget webhook notification for terminal events (masked)
    if occ.type in ["ci.run.passed", "ci.run.failed"] do
      secrets = collect_secrets_from_env()
      masked = Sykli.Services.SecretMasker.mask_deep(to_persistence_map(enriched), secrets)
      Sykli.Services.NotificationService.notify(masked)
    end

    result
  end

  @doc """
  Enriches a terminal occurrence with FALSE Protocol blocks (without persisting).
  """
  @spec enrich(Occurrence.t(), map(), {:ok | :error, [TaskResult.t()]} | term(), String.t()) ::
          Occurrence.t()
  def enrich(%Occurrence{} = occ, graph, executor_result, workdir) do
    results = extract_results(executor_result)
    task_names = Enum.map(results, & &1.name)
    history_map = HistoryAnalyzer.analyze(task_names, workdir)

    failed_names =
      results
      |> Enum.filter(&(&1.status in [:failed, :errored]))
      |> Enum.map(& &1.name)

    likely_causes =
      CausalityService.analyze(failed_names, graph, workdir, get_field: &get_field/2)

    # Build domain-specific data (was ci_data, now goes into data per spec)
    ci_data = build_ci_data(results, graph, history_map, occ.run_id, workdir)

    # Build reasoning — returns {reasoning_block, extra_data} where extra_data
    # contains per-task reasoning and last_good_ref (not spec-conformant in reasoning)
    {reasoning, reasoning_data} =
      build_reasoning_block(results, graph, likely_causes, workdir)

    # Merge error-related CI-specific fields into data
    error_data = build_error_data(results, workdir)

    # Build cross-run analysis (goes into data, not history — spec is strict)
    cross_run_data = build_cross_run_data(results)

    # Merge all into data
    merged_data =
      ci_data
      |> maybe_merge(reasoning_data)
      |> maybe_merge(error_data)
      |> maybe_merge(cross_run_data)

    %{
      occ
      | error: build_error_block(results, graph, likely_causes, workdir),
        reasoning: reasoning,
        history: build_history_block(results, occ.timestamp, graph),
        data: merged_data
    }
  end

  defp maybe_merge(map, nil), do: map
  defp maybe_merge(map, other) when other == %{}, do: map
  defp maybe_merge(map, other), do: Map.merge(map, other)

  # ─────────────────────────────────────────────────────────────────────────────
  # FALSE PROTOCOL: ERROR BLOCK
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_error_block(results, graph, likely_causes, workdir) do
    failed = Enum.filter(results, &(&1.status in [:failed, :errored]))

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

  defp build_task_error(%TaskResult{} = result, graph, likely_causes, _workdir) do
    task = Map.get(graph, result.name, %{})
    blocks = find_blocks(result.name, graph)

    %{
      "code" => error_code(result.error),
      "what_failed" => what_failed(result, task),
      "message" => error_message(result.error),
      "why_it_matters" => why_it_matters(blocks),
      "possible_causes" => build_possible_causes([result], likely_causes),
      "suggested_fix" => suggested_fix(result.error)
    }
    |> reject_empty()
  end

  defp error_code(%Sykli.Error{code: code}), do: code
  defp error_code(:dependency_failed), do: "dependency_failed"
  defp error_code(_), do: "unknown"

  defp error_message(%Sykli.Error{message: msg}), do: msg
  defp error_message(:dependency_failed), do: "blocked by failed dependency"
  defp error_message(_), do: nil

  # Build CI-specific error fields that move into data (not spec Error)
  defp build_error_data(results, workdir) do
    failed = Enum.filter(results, &(&1.status in [:failed, :errored]))
    if failed == [], do: nil, else: do_build_error_data(failed, workdir)
  end

  defp do_build_error_data(failed, workdir) do
    error_details =
      Enum.flat_map(failed, fn result ->
        locations =
          case result.error do
            %Sykli.Error{locations: locs} when locs != [] ->
              ErrorContext.enrich_locations(locs, workdir)

            _ ->
              ErrorContext.enrich(error_output(result.error), workdir)
          end

        detail =
          %{}
          |> maybe_add("task", result.name)
          |> maybe_add("output", truncate_output(error_output(result.error)))
          |> maybe_add("exit_code", error_exit_code(result.error))
          |> maybe_add("locations", non_empty(locations))

        if detail == %{}, do: [], else: [detail]
      end)

    case error_details do
      [] -> nil
      details -> %{"error_details" => details}
    end
  end

  defp what_failed(%TaskResult{name: name}, task) do
    command = get_field(task, :command)
    if command, do: "task '#{name}' command: #{command}", else: "task '#{name}'"
  end

  defp why_it_matters(blocks) do
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
    Enum.find_value(failed_results, fn r -> suggested_fix(r.error) end)
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

  # Returns {reasoning_block | nil, extra_data | nil}
  defp build_reasoning_block(results, _graph, likely_causes, workdir) do
    failed = Enum.filter(results, &(&1.status in [:failed, :errored]))
    if failed == [], do: {nil, nil}, else: do_build_reasoning(failed, likely_causes, workdir)
  end

  defp do_build_reasoning(failed, likely_causes, workdir) do
    task_reasonings =
      Enum.map(failed, fn r ->
        case Map.get(likely_causes, r.name) do
          %{changed_files: files, explanation: explanation} when files != [] ->
            %{task: r.name, files: files, explanation: explanation, confidence: 0.8}

          _ ->
            %{task: r.name, files: [], explanation: "no direct file correlation", confidence: 0.2}
        end
      end)

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

    # Build full explanation narrative from task analyses
    explanation = build_explanation(task_reasonings)

    confidence = if(best, do: best.confidence, else: 0.1)

    # Spec-conformant reasoning block (summary + explanation + confidence only)
    reasoning = %{
      "summary" => summary,
      "explanation" => explanation,
      "confidence" => confidence
    }

    # Per-task reasoning and last_good_ref go into data (not in spec Reasoning)
    last_good_ref =
      case RunHistory.load_last_good(path: workdir) do
        {:ok, run} -> run.git_ref
        _ -> nil
      end

    per_task =
      Map.new(task_reasonings, fn r ->
        {r.task, %{"changed_files" => r.files, "explanation" => r.explanation}}
      end)

    extra_data =
      %{"reasoning_details" => %{"tasks" => per_task}}
      |> maybe_add("last_good_ref", last_good_ref)

    {reasoning, extra_data}
  end

  defp build_explanation(task_reasonings) do
    task_reasonings
    |> Enum.map(fn r ->
      case r.files do
        [_ | _] ->
          files_str = Enum.join(r.files, ", ")
          "The #{r.task} task failed after #{files_str} changed. #{r.explanation}."

        [] ->
          "The #{r.task} task failed. #{r.explanation}."
      end
    end)
    |> Enum.join(" ")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FALSE PROTOCOL: HISTORY BLOCK
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_history_block(results, base_timestamp, graph) do
    # Build steps with computed timestamps offset from the occurrence timestamp
    {steps, _} =
      Enum.map_reduce(results, 0, fn %TaskResult{} = r, offset_ms ->
        step_ts =
          base_timestamp
          |> DateTime.add(offset_ms, :millisecond)
          |> DateTime.to_iso8601()

        step = %{
          "timestamp" => step_ts,
          "action" => r.name,
          "description" => step_command_description(r, graph),
          "outcome" => map_step_outcome(r.status),
          "duration_ms" => r.duration_ms
        }

        step =
          case r.error do
            %Sykli.Error{} = err ->
              Map.put(step, "error", %{
                "code" => err.code,
                "what_failed" => err.message || "task #{r.name} failed"
              })

            :dependency_failed ->
              Map.put(step, "error", %{
                "code" => "dependency_failed",
                "what_failed" => "blocked by failed dependency"
              })

            _ ->
              step
          end

        # Remove nil description
        step = if step["description"], do: step, else: Map.delete(step, "description")

        {step, offset_ms + r.duration_ms}
      end)

    duration_ms = results |> Enum.map(& &1.duration_ms) |> Enum.sum()

    %{"steps" => steps, "duration_ms" => duration_ms}
  end

  defp step_command_description(%TaskResult{name: name}, graph) do
    case Map.get(graph, name) do
      nil -> nil
      task -> get_field(task, :command)
    end
  end

  defp map_step_outcome(:passed), do: "success"
  defp map_step_outcome(:cached), do: "success"
  defp map_step_outcome(:failed), do: "failure"
  defp map_step_outcome(:errored), do: "error"
  defp map_step_outcome(:blocked), do: "failure"
  defp map_step_outcome(:skipped), do: "skipped"

  defp build_cross_run_data(results) do
    case safe_store_list(20) do
      [] ->
        nil

      previous_occurrences ->
        recent = build_recent_outcomes(results, previous_occurrences)
        regression = detect_regression(results, previous_occurrences)

        result = %{}
        result = if recent != %{}, do: Map.put(result, "recent_outcomes", recent), else: result

        result =
          if regression, do: Map.put(result, "regression", regression), else: result

        if result == %{}, do: nil, else: result
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
          tasks = get_occ_tasks(occ)

          case Enum.find(tasks, &(task_name_from_occ(&1) == r.name)) do
            nil -> []
            task_entry -> [normalize_task_outcome(task_status_from_occ(task_entry))]
          end
        end)

      {r.name, outcomes}
    end)
    |> Enum.reject(fn {_name, outcomes} -> outcomes == [] end)
    |> Map.new()
  end

  defp detect_regression(results, previous_occurrences) do
    failed_now = Enum.filter(results, &(&1.status in [:failed, :errored]))
    if failed_now == [], do: nil, else: do_detect_regression(failed_now, previous_occurrences)
  end

  defp do_detect_regression(failed_now, previous_occurrences) do
    new_failures =
      Enum.filter(failed_now, fn r ->
        Enum.all?(previous_occurrences, fn occ ->
          tasks = get_occ_tasks(occ)

          case Enum.find(tasks, &(task_name_from_occ(&1) == r.name)) do
            nil -> false
            task_entry -> task_status_from_occ(task_entry) in ["passed", "cached"]
          end
        end)
      end)

    case new_failures do
      [] -> nil
      failures -> %{"is_new_failure" => true, "tasks" => Enum.map(failures, & &1.name)}
    end
  end

  # Handle old format (ci_data at top level), new struct format (data), and new map format
  defp get_occ_tasks(%Occurrence{data: %{"tasks" => tasks}}), do: tasks || []
  defp get_occ_tasks(%{"data" => %{"tasks" => tasks}}), do: tasks || []
  # Backward compat: old persisted occurrences had ci_data at top level
  defp get_occ_tasks(%{"ci_data" => %{"tasks" => tasks}}), do: tasks || []
  defp get_occ_tasks(_), do: []

  defp task_name_from_occ(%{"name" => name}), do: name
  defp task_name_from_occ(_), do: nil

  defp task_status_from_occ(%{"status" => status}), do: status
  defp task_status_from_occ(_), do: nil

  defp normalize_task_outcome("passed"), do: "pass"
  defp normalize_task_outcome("cached"), do: "pass"
  defp normalize_task_outcome("failed"), do: "fail"
  defp normalize_task_outcome("errored"), do: "fail"
  defp normalize_task_outcome("skipped"), do: "skip"
  defp normalize_task_outcome("blocked"), do: "skip"
  defp normalize_task_outcome(other), do: other

  # ─────────────────────────────────────────────────────────────────────────────
  # CI DATA (Domain-Specific Payload)
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_ci_data(results, graph, history_map, run_id, workdir) do
    passed = Enum.count(results, &(&1.status in [:passed, :cached]))
    failed = Enum.count(results, &(&1.status == :failed))
    errored = Enum.count(results, &(&1.status == :errored))
    cached = Enum.count(results, &(&1.status == :cached))
    skipped = Enum.count(results, &(&1.status in [:skipped, :blocked]))

    %{
      "git" => GitContext.collect(workdir),
      "summary" => %{
        "passed" => passed,
        "failed" => failed,
        "errored" => errored,
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

  # Keep backward compat
  defdelegate error_to_map(error), to: __MODULE__, as: :error_detail_map

  # ─────────────────────────────────────────────────────────────────────────────
  # PERSISTENCE
  # ─────────────────────────────────────────────────────────────────────────────

  @max_json_occurrences 20

  defp persist(%Occurrence{} = occ, workdir) do
    occurrence_map = to_persistence_map(occ)

    # Mask any resolved secrets from the occurrence data before persisting
    secrets = collect_secrets_from_env()

    occurrence_map =
      if secrets != [] do
        Sykli.Services.SecretMasker.mask_deep(occurrence_map, secrets)
      else
        occurrence_map
      end

    dir = Path.join(workdir, ".sykli")

    with :ok <- File.mkdir_p(dir) do
      # 1. JSON — per-run files for AI/external consumers (keep last N)
      json_dir = Path.join(dir, "occurrences_json")
      File.mkdir_p!(json_dir)
      json_path = Path.join(json_dir, "#{occ.run_id}.json")
      json = Jason.encode!(occurrence_map, pretty: true)
      :ok = File.write(json_path, json)

      # Also write latest as occurrence.json for quick access
      latest_path = Path.join(dir, "occurrence.json")
      :ok = File.write(latest_path, json)

      # Evict old JSON files (keep last N)
      evict_old_files(json_dir, @max_json_occurrences, ".json")

      # 2. ETF — warm path for fast sykli reload
      etf_dir = Path.join(dir, "occurrences")
      File.mkdir_p!(etf_dir)
      filename = "#{occ.run_id}.etf"
      etf_path = Path.join(etf_dir, filename)
      File.write!(etf_path, :erlang.term_to_binary(occurrence_map))

      # 3. ETS — hot path if store is running
      safe_store_put(occurrence_map)

      # 4. Evict old .etf files (keep last 50)
      evict_old_files(etf_dir, 50, ".etf")

      :ok
    end
  end

  @doc """
  Converts an enriched Occurrence struct to the persistence map format
  (string keys, conforming to FALSE Protocol occurrence.json schema).
  """
  @spec to_persistence_map(Occurrence.t()) :: map()
  def to_persistence_map(%Occurrence{} = occ) do
    context =
      (occ.context || %{})
      |> Map.put("labels", %{
        "sykli.run_id" => occ.run_id,
        "sykli.node" => to_string(occ.node)
      })

    base = %{
      "protocol_version" => occ.protocol_version,
      "id" => occ.id,
      "timestamp" => DateTime.to_iso8601(occ.timestamp),
      "source" => occ.source,
      "type" => occ.type,
      "severity" => to_string(occ.severity),
      "outcome" => occ.outcome,
      "context" => context
    }

    base
    |> maybe_add("error", occ.error)
    |> maybe_add("reasoning", occ.reasoning)
    |> maybe_add("history", occ.history)
    |> maybe_add("data", encode_data(occ.data))
  end

  defp encode_data(nil), do: nil
  defp encode_data(data) when is_struct(data), do: Map.from_struct(data)
  defp encode_data(data) when is_map(data), do: data

  defp safe_store_put(occurrence) do
    Store.put(occurrence)
  catch
    :exit, _ -> :ok
    :error, _ -> :ok
  end

  # Evict oldest files by name (ULID filenames are lexicographically time-sorted)
  defp evict_old_files(dir, max, extension) do
    case File.ls(dir) do
      {:ok, files} ->
        matching =
          files
          |> Enum.filter(&String.ends_with?(&1, extension))
          |> Enum.sort()

        if length(matching) > max do
          matching
          |> Enum.take(length(matching) - max)
          |> Enum.each(fn file -> File.rm(Path.join(dir, file)) end)
        end

      {:error, _} ->
        :ok
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SLSA ATTESTATION
  # ─────────────────────────────────────────────────────────────────────────────

  defp persist_attestation(enriched, graph, workdir) do
    dir = Path.join(workdir, ".sykli")

    # Per-run attestation
    case Sykli.Attestation.generate(enriched, graph, workdir) do
      {:ok, attestation} ->
        write_attestation(attestation, Path.join(dir, "attestation.json"))

      {:error, :no_subjects} ->
        :ok
    end

    # Per-task attestations (for artifact registries)
    per_task = Sykli.Attestation.generate_per_task(enriched, graph, workdir)

    if per_task != [] do
      att_dir = Path.join(dir, "attestations")

      case File.mkdir_p(att_dir) do
        :ok ->
          Enum.each(per_task, fn {task_name, attestation} ->
            safe_name = String.replace(task_name, "/", ":")
            write_attestation(attestation, Path.join(att_dir, "#{safe_name}.json"))
          end)

        {:error, _} ->
          :ok
      end
    end
  end

  # Write attestation as DSSE envelope (signed if key available, unsigned otherwise)
  defp write_attestation(attestation, path) do
    {:ok, envelope} = Sykli.Attestation.Envelope.wrap(attestation)

    envelope =
      if signing_key_configured?() do
        case Sykli.Attestation.Envelope.sign(envelope, Sykli.Attestation.Signer.HMAC) do
          {:ok, signed} -> signed
          _ -> envelope
        end
      else
        envelope
      end

    json = Jason.encode!(envelope, pretty: true)

    case File.write(path, json) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  defp signing_key_configured? do
    key =
      System.get_env("SYKLI_SIGNING_KEY") ||
        Application.get_env(:sykli, :signing_key)

    is_binary(key) and key != ""
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

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

  # Collect secret values from common env var patterns for masking
  @secret_env_patterns ["_TOKEN", "_SECRET", "_KEY", "_PASSWORD", "_PASS", "_API_KEY"]
  defp collect_secrets_from_env do
    System.get_env()
    |> Enum.filter(fn {key, _val} ->
      Enum.any?(@secret_env_patterns, &String.contains?(key, &1))
    end)
    |> Enum.map(fn {_key, val} -> val end)
    |> Enum.filter(&(byte_size(&1) >= 4))
  end
end
