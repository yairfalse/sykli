defmodule Sykli.GitHub.Dispatcher do
  @moduledoc "Dispatches accepted GitHub webhooks into executor runs."

  require Logger

  alias Sykli.GitHub.CheckRunFormatter
  alias Sykli.GitHub.Webhook.Deliveries
  alias Sykli.Occurrence.PubSub, as: OccPubSub

  @spec dispatch(map(), keyword()) :: :ok | {:error, Sykli.Error.t()}
  def dispatch(%{delivery_id: delivery_id} = event, opts \\ []) do
    run_id = Map.get(event, :run_id) || "github:#{delivery_id}"
    event = Map.put(event, :run_id, run_id)

    case do_dispatch(event, opts) do
      :ok ->
        :ok

      {:error, %Sykli.Error{} = error} = result ->
        if retryable_dispatch_error?(error) do
          Deliveries.evict(delivery_id)
          Logger.warning("[GitHub Dispatcher] dispatch failed", code: error.code)
        else
          Logger.warning("[GitHub Dispatcher] App auth failed; delivery will not be retried",
            code: error.code
          )
        end

        result
    end
  end

  defp do_dispatch(event, opts) do
    run_id = event.run_id

    OccPubSub.github_run_dispatched(run_id, %{
      event: event.event,
      delivery_id: event.delivery_id,
      repo: event.repo,
      head_sha: event.head_sha
    })

    with {:ok, token, _expires_at} <-
           app_client(opts).installation_token(event.installation_id, opts),
         {:ok, suite} <- create_suite(event, token, opts) do
      dispatch_after_suite(event, token, suite, opts)
    else
      {:error, %Sykli.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, dispatch_error("github.dispatch.failed", "GitHub dispatch failed", reason)}
    end
  end

  defp dispatch_after_suite(event, token, suite, opts) do
    run_id = event.run_id

    with {:ok, source_path, janitor} <- acquire_source(event, token, opts),
         {:ok, results} <- dispatch_from_source(event, token, source_path, janitor, opts) do
      OccPubSub.github_check_suite_concluded(run_id, %{
        repo: event.repo,
        head_sha: event.head_sha,
        check_suite_id: suite["id"],
        conclusion: suite_conclusion(results)
      })

      :ok
    else
      {:error, %Sykli.Error{} = error} ->
        maybe_emit_source_failed(run_id, event, error)
        create_setup_failure(event, token, error, opts)

        OccPubSub.github_check_suite_concluded(run_id, %{
          repo: event.repo,
          head_sha: event.head_sha,
          check_suite_id: suite["id"],
          conclusion: "failure"
        })

        {:error, error}

      {:error, reason} ->
        error = dispatch_error("github.dispatch.failed", "GitHub dispatch failed", reason)
        maybe_emit_source_failed(run_id, event, error)
        create_setup_failure(event, token, error, opts)

        OccPubSub.github_check_suite_concluded(run_id, %{
          repo: event.repo,
          head_sha: event.head_sha,
          check_suite_id: suite["id"],
          conclusion: "failure"
        })

        {:error, error}
    end
  end

  defp dispatch_from_source(event, token, source_path, janitor, opts) do
    try do
      maybe_after_source_acquired(source_path, opts)

      with {:ok, graph, tasks} <- load_graph(source_path),
           {:ok, check_runs} <- create_task_runs(event, token, tasks, opts),
           :ok <- mark_in_progress(event, token, check_runs, opts),
           {:ok, results} <- run_executor(tasks, graph, source_path, event.run_id, opts),
           :ok <- conclude_task_runs(event, token, check_runs, results, opts) do
        {:ok, results}
      end
    after
      case workspace_janitor(opts).cleanup(janitor) do
        :ok ->
          :ok

        {:error, :timeout} ->
          Logger.warning("[GitHub Dispatcher] source workspace cleanup timed out")
      end
    end
  end

  defp maybe_after_source_acquired(source_path, opts) do
    case Keyword.get(opts, :after_source_acquired) do
      callback when is_function(callback, 1) -> callback.(source_path)
      _ -> :ok
    end
  end

  defp create_suite(event, token, opts) do
    case checks_client(opts).create_suite(
           %{repo: event.repo, head_sha: event.head_sha},
           token,
           opts
         ) do
      {:ok, suite} ->
        OccPubSub.github_check_suite_opened(event.run_id, %{
          repo: event.repo,
          head_sha: event.head_sha,
          check_suite_id: suite["id"]
        })

        {:ok, suite}

      error ->
        error
    end
  end

  defp acquire_source(event, token, opts) do
    case Sykli.GitHub.Source.acquire(event, token, opts) do
      {:ok, path} ->
        case workspace_janitor(opts).start(self(), path, opts) do
          {:ok, janitor} ->
            OccPubSub.github_run_source_acquired(event.run_id, %{
              repo: event.repo,
              sha: event.head_sha,
              path: path,
              bytes: directory_bytes(path)
            })

            {:ok, path, janitor}

          {:error, reason} ->
            Sykli.GitHub.Source.cleanup(path, opts)

            {:error,
             dispatch_error(
               "github.dispatch.workspace_janitor_failed",
               "failed to monitor source workspace cleanup",
               reason
             )}
        end

      error ->
        error
    end
  end

  defp load_graph(source_path) do
    with {:ok, sdk_file} <- Sykli.Detector.find(source_path),
         {:ok, json} <- Sykli.Detector.emit(sdk_file),
         {:ok, graph} <- Sykli.Graph.parse(json),
         expanded <- Sykli.Graph.expand_matrix(graph),
         {:ok, tasks} <- Sykli.Graph.topo_sort(expanded) do
      {:ok, expanded, tasks}
    else
      {:error, :no_sdk_file} ->
        {:error,
         dispatch_error(
           "github.dispatch.no_pipeline",
           "no sykli pipeline was found in the cloned source"
         )}

      {:error, reason} ->
        {:error,
         dispatch_error("github.dispatch.graph_failed", "failed to build task graph", reason)}
    end
  end

  defp create_task_runs(event, token, tasks, opts) do
    Enum.reduce_while(tasks, {:ok, %{}}, fn task, {:ok, acc} ->
      case checks_client(opts).create_run(
             %{repo: event.repo, head_sha: event.head_sha},
             token,
             Keyword.put(opts, :name, task.name)
           ) do
        {:ok, run} ->
          check_run_id = run["id"]

          OccPubSub.github_check_run_created(event.run_id, %{
            task_name: task.name,
            check_run_id: check_run_id
          })

          {:cont, {:ok, Map.put(acc, task.name, check_run_id)}}

        {:error, %Sykli.Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp mark_in_progress(event, token, check_runs, opts) do
    check_runs
    |> Enum.each(fn {task_name, check_run_id} ->
      transition_check_run(
        event,
        token,
        task_name,
        check_run_id,
        "queued",
        "in_progress",
        %{
          status: "in_progress"
        },
        opts
      )
    end)

    :ok
  end

  defp run_executor(tasks, graph, source_path, run_id, opts) do
    exec_opts =
      opts
      |> Keyword.put(:workdir, source_path)
      |> Keyword.put(:run_id, run_id)

    case run_executor_quietly(tasks, graph, exec_opts) do
      {:ok, results} ->
        {:ok, results}

      {:error, results} when is_list(results) ->
        {:ok, results}

      {:error, %Sykli.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, dispatch_error("github.dispatch.executor_failed", "executor failed", reason)}
    end
  end

  defp run_executor_quietly(tasks, graph, opts) do
    original_group_leader = Process.group_leader()

    {:ok, io} = StringIO.open("")
    Process.group_leader(self(), io)

    try do
      Sykli.Executor.run(tasks, graph, opts)
    after
      Process.group_leader(self(), original_group_leader)
      StringIO.close(io)
    end
  end

  defp conclude_task_runs(event, token, check_runs, results, opts) do
    Enum.each(results, fn result ->
      case Map.fetch(check_runs, result.name) do
        {:ok, check_run_id} ->
          formatted = CheckRunFormatter.format(result)

          attrs = %{
            status: "completed",
            conclusion: CheckRunFormatter.conclusion(result),
            output: formatted
          }

          transition_check_run(
            event,
            token,
            result.name,
            check_run_id,
            "in_progress",
            "completed",
            attrs,
            opts
          )

        :error ->
          :ok
      end
    end)

    :ok
  end

  defp create_setup_failure(event, token, %Sykli.Error{} = error, opts) do
    with {:ok, run} <-
           checks_client(opts).create_run(
             %{repo: event.repo, head_sha: event.head_sha},
             token,
             Keyword.put(opts, :name, "sykli/source")
           ) do
      check_run_id = run["id"]

      transition_check_run(
        event,
        token,
        "sykli/source",
        check_run_id,
        "queued",
        "completed",
        %{
          status: "completed",
          conclusion: "failure",
          output: %{
            title: "sykli/source: failed",
            summary: "Sykli could not prepare the webhook run.\n\n```text\n#{error.message}\n```"
          }
        },
        opts
      )
    end

    :ok
  end

  defp transition_check_run(event, token, task_name, check_run_id, from, to, attrs, opts) do
    case checks_client(opts).update_run(
           %{repo: event.repo, check_run_id: check_run_id},
           token,
           attrs,
           opts
         ) do
      {:ok, _run} ->
        OccPubSub.github_check_run_transitioned(event.run_id, %{
          from: from,
          to: to,
          task_name: task_name,
          check_run_id: check_run_id
        })

      {:error, %Sykli.Error{} = error} ->
        OccPubSub.github_check_run_transition_failed(event.run_id, %{
          from: from,
          to: to,
          task_name: task_name,
          check_run_id: check_run_id,
          error: %{code: error.code, message: error.message}
        })

        Logger.warning("[GitHub Dispatcher] check run transition failed", code: error.code)
    end
  end

  @doc false
  @spec suite_conclusion([Sykli.Executor.TaskResult.t()]) :: String.t()
  def suite_conclusion([]), do: "success"

  def suite_conclusion(results) do
    conclusions = Enum.map(results, &CheckRunFormatter.conclusion/1)

    cond do
      Enum.any?(conclusions, &(&1 == "failure")) -> "failure"
      Enum.any?(conclusions, &(&1 == "cancelled")) -> "cancelled"
      Enum.all?(conclusions, &(&1 == "skipped")) -> "skipped"
      true -> "success"
    end
  end

  defp maybe_emit_source_failed(run_id, event, %Sykli.Error{} = error) do
    if error.code in [
         "github.source.clone_failed",
         "github.source.checkout_failed",
         "github.source.copy_failed"
       ] do
      OccPubSub.github_run_source_failed(run_id, %{
        repo: event.repo,
        sha: event.head_sha,
        error: %{code: error.code, message: error.message}
      })
    end
  end

  defp directory_bytes(path) do
    path
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reduce(0, fn file, acc ->
      case File.stat(file) do
        {:ok, stat} -> acc + stat.size
        {:error, _} -> acc
      end
    end)
  end

  defp app_client(opts),
    do:
      Keyword.get(
        opts,
        :app_client,
        Application.get_env(:sykli, :github_app_impl, Sykli.GitHub.App)
      )

  defp checks_client(opts), do: Keyword.get(opts, :checks_client, Sykli.GitHub.Checks)

  defp workspace_janitor(opts),
    do: Keyword.get(opts, :workspace_janitor, Sykli.GitHub.WorkspaceJanitor)

  defp retryable_dispatch_error?(%Sykli.Error{code: code})
       when code in [
              "github.app.missing_config",
              "github.app.private_key_not_found",
              "github.app.jwt_failed",
              "github.app.unauthorized"
            ],
       do: false

  defp retryable_dispatch_error?(%Sykli.Error{}), do: true

  defp dispatch_error(code, message, cause \\ nil) do
    %Sykli.Error{
      code: code,
      type: :runtime,
      message: message,
      step: :run,
      cause: cause,
      hints: []
    }
  end
end
