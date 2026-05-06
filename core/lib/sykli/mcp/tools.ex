defmodule Sykli.MCP.Tools do
  @moduledoc """
  MCP tool definitions and implementations.

  Five tools that expose sykli's core capabilities to AI assistants:

  - `run_pipeline` — execute the pipeline
  - `explain_pipeline` — describe pipeline structure
  - `get_failure` — get last failure with error context
  - `suggest_tests` — which tasks to run for changed files
  - `get_history` — recent runs with patterns
  """

  alias Sykli.{Detector, Graph, Explain, RunHistory, Delta, Context}

  @doc """
  Returns the list of MCP tool definitions.
  """
  @spec list() :: [map()]
  def list do
    [
      %{
        "name" => "run_pipeline",
        "description" =>
          "Execute the sykli CI pipeline. Returns task statuses, durations, and errors.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Project path (default: current directory)"
            },
            "tasks" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Only run these specific tasks (default: all)"
            },
            "timeout" => %{
              "type" => "integer",
              "description" => "Per-task timeout in milliseconds (default: 300000)"
            }
          }
        }
      },
      %{
        "name" => "explain_pipeline",
        "description" =>
          "Describe the pipeline structure: tasks, dependencies, execution levels, critical path, and semantic metadata. Zero-cost read-only operation.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Project path (default: current directory)"
            }
          }
        }
      },
      %{
        "name" => "get_failure",
        "description" =>
          "Get the last failure occurrence with full error context: error type, code location, recent changes, blame, and suggested fix.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Project path (default: current directory)"
            },
            "run_id" => %{
              "type" => "string",
              "description" => "Specific run ID to inspect (default: latest)"
            }
          }
        }
      },
      %{
        "name" => "suggest_tests",
        "description" =>
          "Suggest which tasks to run based on changed files. Uses semantic coverage and dependency analysis to find affected and skippable tasks.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Project path (default: current directory)"
            },
            "changed_files" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "List of changed files to analyze. If omitted, uses git diff against HEAD."
            }
          }
        }
      },
      %{
        "name" => "get_history",
        "description" =>
          "Get recent run history with computed patterns: success rate, average duration, flaky tasks.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Project path (default: current directory)"
            },
            "limit" => %{
              "type" => "integer",
              "description" => "Number of runs to return (default: 10)"
            }
          }
        }
      },
      %{
        "name" => "retry_task",
        "description" =>
          "Re-run specific task(s) by name. Re-detects the SDK, re-emits the graph, and executes only the named tasks.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Project path (default: current directory)"
            },
            "tasks" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Task names to retry"
            }
          },
          "required" => ["tasks"]
        }
      },
      %{
        "name" => "run_fix",
        "description" =>
          "Analyze the last failure: identify failed tasks, correlate with git changes, extract error locations, and suggest fixes. Returns structured JSON.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Project path (default: current directory)"
            },
            "task" => %{
              "type" => "string",
              "description" => "Specific task name to analyze (default: all failed)"
            }
          }
        }
      }
    ]
  end

  @doc """
  Dispatches a tool call by name.

  Returns `{:ok, result_map}` or `{:error, message}`.
  """
  @spec call(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def call(name, arguments) do
    do_call(name, arguments)
  rescue
    e ->
      {:error, "Tool crashed: #{Exception.message(e)}"}
  end

  # --- Tool implementations ---

  defp do_call("run_pipeline", args) do
    path = args["path"] || "."
    opts = build_run_opts(args)

    case Sykli.run(path, opts) do
      {:ok, results} ->
        {:ok,
         %{
           status: "passed",
           tasks:
             Enum.map(results, fn r ->
               %{
                 name: r.name,
                 status: "passed",
                 duration_ms: r.duration_ms,
                 cached: r.cached
               }
             end)
         }}

      {:error, results} when is_list(results) ->
        {:ok,
         %{
           status: "failed",
           tasks:
             Enum.map(results, fn r ->
               base = %{
                 name: r.name,
                 status: to_string(r.status),
                 duration_ms: r.duration_ms,
                 cached: r.cached
               }

               if r.error, do: Map.put(base, :error, r.error), else: base
             end)
         }}

      {:error, reason} ->
        {:error, "Pipeline failed: #{inspect(reason)}"}
    end
  end

  defp do_call("explain_pipeline", args) do
    path = args["path"] || "."

    with {:ok, sdk_file} <- Detector.find(path),
         {:ok, json} <- Detector.emit(sdk_file),
         {:ok, graph} <- Graph.parse(json) do
      expanded = Graph.expand_matrix(graph)
      sdk_name = Path.basename(elem(sdk_file, 0))

      run_history =
        case RunHistory.load_latest(path: path) do
          {:ok, run} -> run
          {:error, _} -> nil
        end

      explanation = Explain.pipeline(expanded, sdk_file: sdk_name, run_history: run_history)
      {:ok, explanation}
    else
      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp do_call("get_failure", args) do
    path = args["path"] || "."
    run_id = args["run_id"]

    # Try hot path (ETS) first, fall back to cold path (JSON file)
    occurrence =
      if run_id do
        safe_store_call(fn -> Sykli.Occurrence.Store.get(run_id) end)
      else
        safe_store_call(fn -> Sykli.Occurrence.Store.get_latest() end)
      end

    occurrence = occurrence || load_occurrence_cold(path)

    case occurrence do
      nil ->
        {:error, "No occurrence data found. Run 'sykli' first."}

      data ->
        {:ok, data}
    end
  end

  defp do_call("suggest_tests", args) do
    path = args["path"] || "."

    with {:ok, sdk_file} <- Detector.find(path),
         {:ok, json} <- Detector.emit(sdk_file),
         {:ok, graph} <- Graph.parse(json) do
      expanded = Graph.expand_matrix(graph)
      tasks = Map.values(expanded)

      # Get changed files — either from args or from git
      changed_files =
        case args["changed_files"] do
          nil ->
            case Delta.get_changed_files("HEAD", path) do
              {:ok, files} -> files
              {:error, _} -> []
            end

          files ->
            files
        end

      if changed_files == [] do
        {:ok, %{changed_files: [], affected: [], skipped: [], message: "No changes detected"}}
      else
        # Semantic coverage analysis
        suggested = Context.tasks_for_changes(expanded, changed_files)

        # Dependency-based analysis
        affected_details =
          case Delta.affected_tasks_detailed(tasks, from: "HEAD", path: path) do
            {:ok, details} -> details
            {:error, _} -> []
          end

        all_task_names = Enum.map(tasks, & &1.name)
        affected_names = Enum.map(affected_details, & &1.name)
        suggested_set = MapSet.new(suggested)
        affected_set = MapSet.new(affected_names)
        run_set = MapSet.union(suggested_set, affected_set)

        skipped =
          all_task_names
          |> Enum.reject(&MapSet.member?(run_set, &1))
          |> Enum.map(fn name -> %{name: name, reason: "no relevant changes"} end)

        affected =
          Enum.map(affected_details, fn d ->
            %{
              name: d.name,
              reason: to_string(d.reason),
              files: d.files,
              depends_on: d.depends_on
            }
          end)

        {:ok,
         %{
           changed_files: changed_files,
           affected: affected,
           skipped: skipped
         }}
      end
    else
      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp do_call("get_history", args) do
    path = args["path"] || "."
    limit = args["limit"] || 10

    case RunHistory.list(path: path, limit: limit) do
      {:ok, []} ->
        {:ok, %{runs: [], patterns: %{}}}

      {:ok, runs} ->
        run_maps =
          Enum.map(runs, fn run ->
            %{
              id: run.id,
              timestamp: DateTime.to_iso8601(run.timestamp),
              git_ref: run.git_ref,
              git_branch: run.git_branch,
              overall: Atom.to_string(run.overall),
              task_count: length(run.tasks),
              passed: Enum.count(run.tasks, &(&1.status == :passed)),
              failed: Enum.count(run.tasks, &(&1.status in [:failed, :errored]))
            }
          end)

        # Compute patterns
        total = length(runs)
        passed = Enum.count(runs, &(&1.overall == :passed))
        success_rate = if total > 0, do: Float.round(passed / total, 2), else: 0.0

        all_durations =
          Enum.map(runs, fn run ->
            Enum.reduce(run.tasks, 0, fn t, acc -> acc + (t.duration_ms || 0) end)
          end)

        avg_duration_ms =
          if total > 0, do: div(Enum.sum(all_durations), total), else: 0

        # Find flaky tasks (tasks that both pass and fail across runs)
        task_outcomes =
          Enum.reduce(runs, %{}, fn run, acc ->
            Enum.reduce(run.tasks, acc, fn task, inner ->
              Map.update(inner, task.name, [task.status], &[task.status | &1])
            end)
          end)

        flaky_tasks =
          task_outcomes
          |> Enum.filter(fn {_name, statuses} ->
            :passed in statuses and :failed in statuses
          end)
          |> Enum.map(fn {name, _} -> name end)

        {:ok,
         %{
           runs: run_maps,
           patterns: %{
             total_runs: total,
             success_rate: success_rate,
             avg_duration_ms: avg_duration_ms,
             flaky_tasks: flaky_tasks
           }
         }}
    end
  end

  defp do_call("retry_task", args) do
    path = args["path"] || "."
    task_names = args["tasks"] || []

    if task_names == [] do
      {:error, "No task names provided"}
    else
      name_set = MapSet.new(task_names)
      filter_fn = fn task -> MapSet.member?(name_set, task.name) end
      opts = [filter: filter_fn]

      case Sykli.run(path, opts) do
        {:ok, results} ->
          {:ok,
           %{
             status: "passed",
             retried: task_names,
             tasks:
               Enum.map(results, fn r ->
                 %{name: r.name, status: to_string(r.status), duration_ms: r.duration_ms}
               end)
           }}

        {:error, results} when is_list(results) ->
          {:ok,
           %{
             status: "failed",
             retried: task_names,
             tasks:
               Enum.map(results, fn r ->
                 base = %{name: r.name, status: to_string(r.status), duration_ms: r.duration_ms}
                 if r.error, do: Map.put(base, :error, inspect(r.error)), else: base
               end)
           }}

        {:error, reason} ->
          {:error, "Retry failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_call("run_fix", args) do
    path = args["path"] || "."
    task = args["task"]

    opts = if task, do: [task: task], else: []

    case Sykli.Fix.analyze(path, opts) do
      {:ok, analysis} ->
        {:ok, analysis}

      {:error, :no_occurrence} ->
        {:error, "No occurrence data found. Run 'sykli' first."}

      {:error, :no_failures} ->
        {:ok, %{status: "no_failures", message: "No failed tasks in the last run."}}
    end
  end

  defp do_call(name, _args) do
    {:error, "Unknown tool: #{name}"}
  end

  # --- Helpers ---

  defp build_run_opts(args) do
    opts = []

    opts =
      case args["tasks"] do
        nil ->
          opts

        task_names ->
          name_set = MapSet.new(task_names)
          filter_fn = fn task -> MapSet.member?(name_set, task.name) end
          [{:filter, filter_fn} | opts]
      end

    opts =
      case args["timeout"] do
        nil -> opts
        timeout -> [{:timeout, timeout} | opts]
      end

    opts
  end

  defp safe_store_call(fun) do
    fun.()
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

  defp format_error(:no_sdk_file), do: "No sykli SDK file found (sykli.go, sykli.rs, etc.)"
  defp format_error({:go_failed, msg}), do: "Go SDK failed: #{msg}"
  defp format_error({:rust_failed, msg}), do: "Rust SDK failed: #{msg}"
  defp format_error({:elixir_failed, msg}), do: "Elixir SDK failed: #{msg}"
  defp format_error({:typescript_failed, msg}), do: "TypeScript SDK failed: #{msg}"
  defp format_error({:python_failed, msg}), do: "Python SDK failed: #{msg}"
  defp format_error({:missing_tool, tool, hint}), do: "Missing #{tool}: #{hint}"
  defp format_error({:task_type_on_review, _} = reason), do: Sykli.Graph.format_error(reason)

  defp format_error({:task_type_requires_version_3, _, _, _} = reason),
    do: Sykli.Graph.format_error(reason)

  defp format_error({:unknown_task_type, _, _} = reason), do: Sykli.Graph.format_error(reason)
  defp format_error(reason), do: inspect(reason)
end
