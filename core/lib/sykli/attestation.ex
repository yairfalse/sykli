defmodule Sykli.Attestation do
  @moduledoc """
  Generates SLSA v1.0 provenance attestations from enriched occurrences.

  Synthesizes occurrence data + cache entries into an in-toto Statement v1
  with a SLSA Provenance v1 predicate. Every successful pipeline run
  automatically produces a provenance attestation without user configuration.

  ## How it works

  The enriched occurrence already carries ~80% of what SLSA requires:
  - Git context (SHA, branch, remote URL) → resolvedDependencies
  - Task graph (commands, containers, inputs) → buildDefinition
  - Run metadata (timestamps, run_id, source) → runDetails
  - Cache entries (SHA256 output digests) → subjects

  This module bridges the gap by collecting cache entries for tasks with
  declared outputs and assembling the in-toto envelope.

  ## Output format

  Strict in-toto Statement v1 / SLSA Provenance v1:

      %{
        "_type" => "https://in-toto.io/Statement/v1",
        "subject" => [%{"name" => "app", "digest" => %{"sha256" => "abc..."}}],
        "predicateType" => "https://slsa.dev/provenance/v1",
        "predicate" => %{...}
      }
  """

  alias Sykli.Cache
  alias Sykli.Occurrence

  @statement_type "https://in-toto.io/Statement/v1"
  @predicate_type "https://slsa.dev/provenance/v1"
  @build_type "https://sykli.dev/SykliTask/v1"

  @doc """
  Generates a SLSA v1.0 provenance attestation from an enriched occurrence.

  Takes the enriched occurrence, the task graph, and the workdir.
  Returns `{:ok, attestation_map}` or `{:error, reason}`.

  Only tasks with declared outputs that produced cache entries with SHA256
  digests become SLSA subjects. Tasks without outputs (lint, test) appear
  in the build steps but not as subjects.
  """
  @spec generate(Occurrence.t(), map(), String.t()) :: {:ok, map()} | {:error, :no_subjects}
  def generate(%Occurrence{} = occ, graph, workdir) do
    subjects = collect_subjects(graph, workdir)
    failed = occ.type == "ci.run.failed"

    # Passing runs require at least one subject (artifact with digest).
    # Failed runs are allowed to have no subjects — they attest what was attempted.
    if subjects == [] and not failed do
      {:error, :no_subjects}
    else
      git = get_in(occ.data, ["git"]) || %{}

      attestation = %{
        "_type" => @statement_type,
        "subject" => subjects,
        "predicateType" => @predicate_type,
        "predicate" => %{
          "buildDefinition" => build_definition(occ, graph, git),
          "runDetails" => run_details(occ, git)
        }
      }

      {:ok, attestation}
    end
  end

  @doc """
  Generates individual SLSA attestations for each task that has outputs.

  Returns a list of `{task_name, attestation_map}` tuples.
  Tasks without outputs are skipped.
  """
  @spec generate_per_task(Occurrence.t(), map(), String.t()) :: [{String.t(), map()}]
  def generate_per_task(%Occurrence{} = occ, graph, workdir) do
    git = get_in(occ.data, ["git"]) || %{}
    run = run_details(occ, git)

    graph
    |> Enum.flat_map(fn {name, task} ->
      subjects = collect_task_subjects(task, workdir)

      if subjects == [] do
        []
      else
        task_graph = %{name => task}

        attestation = %{
          "_type" => @statement_type,
          "subject" => subjects,
          "predicateType" => @predicate_type,
          "predicate" => %{
            "buildDefinition" => build_definition(occ, task_graph, git),
            "runDetails" => run
          }
        }

        [{name, attestation}]
      end
    end)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SUBJECTS — artifacts with SHA256 digests from cache entries
  # ─────────────────────────────────────────────────────────────────────────────

  defp collect_subjects(graph, workdir) do
    Enum.flat_map(graph, fn {_name, task} -> collect_task_subjects(task, workdir) end)
  end

  defp collect_task_subjects(task, workdir) do
    if task_outputs(task) == [] do
      []
    else
      case Cache.cache_key(task, workdir) |> Cache.get_entry() do
        {:ok, entry} ->
          (entry.outputs || [])
          |> Enum.map(fn output ->
            %{"name" => output["path"], "digest" => %{"sha256" => output["blob"]}}
          end)
          |> Enum.reject(fn s -> is_nil(s["name"]) or is_nil(s["digest"]["sha256"]) end)

        _ ->
          []
      end
    end
  end

  defp task_outputs(%{outputs: outputs}) when is_map(outputs) and outputs != %{},
    do: Map.values(outputs)

  defp task_outputs(%{outputs: outputs}) when is_list(outputs) and outputs != [],
    do: outputs

  defp task_outputs(_), do: []

  # ─────────────────────────────────────────────────────────────────────────────
  # BUILD DEFINITION — what was supposed to happen
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_definition(occ, graph, git) do
    base = %{
      "buildType" => @build_type,
      "externalParameters" => external_parameters(graph),
      "internalParameters" => internal_parameters(occ)
    }

    deps = resolved_dependencies(git, graph)
    if deps != [], do: Map.put(base, "resolvedDependencies", deps), else: base
  end

  defp external_parameters(graph) do
    tasks =
      graph
      |> Enum.map(fn {name, task} ->
        entry = %{"name" => name}

        entry =
          if task.command, do: Map.put(entry, "command", task.command), else: entry

        entry =
          if task.container, do: Map.put(entry, "container", task.container), else: entry

        entry
      end)
      |> Enum.sort_by(& &1["name"])

    %{"tasks" => tasks}
  end

  defp internal_parameters(%Occurrence{} = occ) do
    %{
      "source" => occ.source,
      "run_id" => occ.run_id
    }
  end

  defp resolved_dependencies(git, graph) do
    git_dep = source_dependency(git)
    container_deps = container_dependencies(graph)
    if git_dep, do: [git_dep | container_deps], else: container_deps
  end

  defp source_dependency(%{"sha" => sha, "remote_url" => url} = git)
       when is_binary(sha) and is_binary(url) do
    branch = git["branch"]

    %{
      "uri" => "git+#{url}",
      "digest" => %{"gitCommit" => sha}
    }
    |> maybe_add_annotation("branch", branch)
  end

  defp source_dependency(_), do: nil

  defp container_dependencies(graph) do
    graph
    |> Enum.map(fn {_name, task} -> task.container end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn image ->
      %{"uri" => "pkg:docker/#{image}"}
    end)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # RUN DETAILS — what actually happened
  # ─────────────────────────────────────────────────────────────────────────────

  defp run_details(%Occurrence{} = occ, git) do
    builder_version = Application.spec(:sykli, :vsn) |> to_string()

    metadata =
      %{
        "invocationId" => occ.run_id,
        "startedOn" => DateTime.to_iso8601(occ.timestamp)
      }
      |> maybe_add_finished(occ)
      |> maybe_put("outcome", occ.outcome)

    base = %{
      "builder" => %{
        "id" => "https://sykli.dev/builder/v1",
        "version" => %{"sykli" => builder_version}
      },
      "metadata" => metadata
    }

    base
  end

  defp maybe_add_finished(metadata, %Occurrence{history: %{"duration_ms" => ms}} = occ)
       when is_integer(ms) do
    finished = DateTime.add(occ.timestamp, ms, :millisecond)
    Map.put(metadata, "finishedOn", DateTime.to_iso8601(finished))
  end

  defp maybe_add_finished(metadata, _), do: metadata

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_annotation(map, _key, nil), do: map

  defp maybe_add_annotation(map, key, value) do
    annotations = Map.get(map, "annotations", %{})
    Map.put(map, "annotations", Map.put(annotations, key, value))
  end
end
