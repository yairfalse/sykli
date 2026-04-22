defmodule Sykli.Occurrence.Serializer do
  @moduledoc """
  Serialization for Occurrence structs.

  Three output formats:
  - **to_json/1** — full JSON for `.sykli/occurrence.json` (AI consumption)
  - **to_kerto/1** — minimal `{type, data, source}` for Kerto knowledge graph
  - **to_ahti/2** — AHTI TapioEvent format for cluster correlation
  """

  alias Sykli.Occurrence

  # ─────────────────────────────────────────────────────────────────────────────
  # JSON
  # ─────────────────────────────────────────────────────────────────────────────

  @doc "Encode an occurrence to JSON string."
  @spec to_json(Occurrence.t()) :: String.t()
  def to_json(%Occurrence{} = occ) do
    occ
    |> to_map()
    |> Jason.encode!()
  end

  @doc "Convert an occurrence to a JSON-friendly map (string keys, no nils)."
  @spec to_map(Occurrence.t()) :: map()
  def to_map(%Occurrence{} = occ) do
    # Build context with labels for run_id/node (not top-level per spec)
    context =
      (occ.context || %{})
      |> Map.put("labels", %{
        "sykli.run_id" => occ.run_id,
        "sykli.node" => to_string(occ.node)
      })

    %{
      "id" => occ.id,
      "timestamp" => DateTime.to_iso8601(occ.timestamp),
      "protocol_version" => occ.protocol_version,
      "type" => occ.type,
      "source" => occ.source,
      "severity" => to_string(occ.severity),
      "context" => context
    }
    |> maybe_add("outcome", occ.outcome)
    |> maybe_add("data", encode_json_data(occ.data))
    |> maybe_add("error", occ.error)
    |> maybe_add("reasoning", occ.reasoning)
    |> maybe_add("history", occ.history)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # KERTO (knowledge graph)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Minimal tuple for Kerto knowledge graph ingestion.

  Returns `{type, data_map, source}`.
  """
  @spec to_kerto(Occurrence.t()) :: {String.t(), map(), String.t()}
  def to_kerto(%Occurrence{} = occ) do
    {occ.type, encode_data(occ.data) || %{}, occ.source}
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # AHTI (TapioEvent format)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Convert to AHTI TapioEvent format.

  ## Options

    * `:namespace` - Kubernetes namespace (optional)
    * `:labels` - Additional labels map (optional)
    * `:source` - Override source (default: from occurrence)
  """
  @spec to_ahti(Occurrence.t(), String.t(), keyword()) :: map()
  def to_ahti(%Occurrence{} = occ, cluster, opts \\ []) do
    ctx = occ.context || %{}

    %{
      id: occ.id,
      timestamp: DateTime.to_iso8601(occ.timestamp),
      type: ahti_event_type(occ.type),
      subtype: ahti_subtype(occ.type),
      severity: ahti_severity(occ),
      outcome: ahti_outcome(occ),
      cluster: cluster,
      namespace: opts[:namespace],
      source: opts[:source] || occ.source,
      trace_id: ctx["trace_id"],
      span_id: ctx["span_id"],
      entities: build_entities(occ, cluster),
      relationships: [],
      labels:
        Map.merge(opts[:labels] || %{}, %{
          "sykli.run_id" => occ.run_id,
          "sykli.node" => to_string(occ.node)
        })
    }
    |> Map.merge(event_specific_data(occ))
    |> remove_nil_values()
  end

  @doc "Encode an occurrence in AHTI format to JSON."
  @spec to_ahti_json(Occurrence.t(), String.t(), keyword()) :: String.t()
  def to_ahti_json(%Occurrence{} = occ, cluster, opts \\ []) do
    occ
    |> to_ahti(cluster, opts)
    |> Jason.encode!()
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # AHTI helpers
  # ─────────────────────────────────────────────────────────────────────────────

  defp ahti_event_type(_type), do: "deployment"

  defp ahti_subtype("ci.run.started"), do: "ci_run_started"
  defp ahti_subtype("ci.run.passed"), do: "ci_run_completed"
  defp ahti_subtype("ci.run.failed"), do: "ci_run_completed"
  defp ahti_subtype("ci.task.started"), do: "ci_task_started"
  defp ahti_subtype("ci.task.completed"), do: "ci_task_completed"
  defp ahti_subtype("ci.task.output"), do: "ci_task_output"
  defp ahti_subtype("ci.gate.waiting"), do: "ci_gate_waiting"
  defp ahti_subtype("ci.gate.resolved"), do: "ci_gate_resolved"
  defp ahti_subtype(type), do: "ci_#{String.replace(type, ".", "_")}"

  defp ahti_severity(%Occurrence{severity: :error}), do: "error"
  defp ahti_severity(%Occurrence{severity: :critical}), do: "critical"
  defp ahti_severity(%Occurrence{severity: :warning}), do: "warning"
  defp ahti_severity(_), do: "info"

  defp ahti_outcome(%Occurrence{outcome: "success"}), do: "success"
  defp ahti_outcome(%Occurrence{outcome: "failure"}), do: "failure"

  defp ahti_outcome(%Occurrence{type: "ci.task.completed", data: data}) do
    case data do
      %{outcome: :success} -> "success"
      %{outcome: :failure} -> "failure"
      _ -> "unknown"
    end
  end

  defp ahti_outcome(%Occurrence{type: "ci.run.passed"}), do: "success"
  defp ahti_outcome(%Occurrence{type: "ci.run.failed"}), do: "failure"
  defp ahti_outcome(_), do: "unknown"

  defp build_entities(%Occurrence{type: "ci.run.started"} = occ, cluster) do
    data = occ.data
    project_path = get_data_field(data, :project_path) || ""
    task_count = get_data_field(data, :task_count) || 0

    [
      %{
        type: "deployment",
        id: "sykli-run-#{occ.run_id}",
        name: "SYKLI Run #{occ.run_id}",
        cluster_id: cluster,
        state: "active",
        attributes: %{
          "project_path" => project_path,
          "task_count" => to_string(task_count)
        }
      }
    ]
  end

  defp build_entities(%Occurrence{type: type} = occ, cluster)
       when type in ["ci.task.started", "ci.task.completed", "ci.task.output"] do
    task_name = get_data_field(occ.data, :task_name) || ""

    [
      %{
        type: "container",
        id: "sykli-task-#{occ.run_id}-#{task_name}",
        name: task_name,
        cluster_id: cluster,
        state: if(type == "ci.task.completed", do: "deleted", else: "active"),
        attributes: %{
          "run_id" => occ.run_id,
          "task_name" => task_name
        }
      }
    ]
  end

  defp build_entities(%Occurrence{type: type} = occ, cluster)
       when type in ["ci.run.passed", "ci.run.failed"] do
    [
      %{
        type: "deployment",
        id: "sykli-run-#{occ.run_id}",
        name: "SYKLI Run #{occ.run_id}",
        cluster_id: cluster,
        state: "deleted",
        delete_reason: if(type == "ci.run.passed", do: "completed", else: "failed")
      }
    ]
  end

  defp build_entities(_occ, _cluster), do: []

  defp event_specific_data(%Occurrence{type: "ci.task.completed", data: data}) do
    task_name = get_data_field(data, :task_name) || ""
    outcome = get_data_field(data, :outcome)

    %{
      process_data: %{
        command: task_name,
        exit_code: if(outcome == :success, do: 0, else: 1)
      }
    }
  end

  defp event_specific_data(%Occurrence{type: "ci.task.output", data: data}) do
    task_name = get_data_field(data, :task_name) || ""
    output = get_data_field(data, :output) || ""

    %{
      process_data: %{
        command: task_name,
        args: String.slice(output, 0, 1000)
      }
    }
  end

  defp event_specific_data(_), do: %{}

  # ─────────────────────────────────────────────────────────────────────────────
  # PRIVATE
  # ─────────────────────────────────────────────────────────────────────────────

  defp get_data_field(data, field) when is_struct(data), do: Map.get(data, field)
  defp get_data_field(data, field) when is_map(data), do: data[field]
  defp get_data_field(_, _), do: nil

  defp encode_data(nil), do: nil
  defp encode_data(data) when is_struct(data), do: Map.from_struct(data)
  defp encode_data(data) when is_map(data), do: data

  defp encode_json_data(nil), do: nil

  defp encode_json_data(data) when is_struct(data),
    do: data |> Map.from_struct() |> stringify_keys()

  defp encode_json_data(data) when is_map(data), do: stringify_keys(data)

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp remove_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, remove_nil_values(v)} end)
    |> Map.new()
  end

  defp remove_nil_values(value), do: value
end
