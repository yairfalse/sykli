defmodule Sykli.ContractSlice do
  @moduledoc """
  Small task contract projection stored with result evidence.

  A contract slice is not a pipeline schema field. It is a post-parse snapshot of
  the already-declared task semantics that explain what law applied to a task
  result. Keep this reference-sized: no logs, source, artifacts, or raw outputs.
  """

  alias Sykli.EvidenceRequirement
  alias Sykli.Graph.Task
  alias Sykli.Graph.Task.{AiHooks, Capability, Gate, Semantic}
  alias Sykli.SuccessCriteria

  @type t :: map()

  @doc "Builds a compact, JSON-compatible contract slice for a graph task."
  @spec from_task(Task.t() | map() | nil) :: t() | nil
  def from_task(nil), do: nil
  def from_task(%{} = task) when map_size(task) == 0, do: nil

  def from_task(%Task{} = task) do
    %{}
    |> maybe_put("kind", Atom.to_string(Task.kind(task)))
    |> maybe_put("task_type", Task.task_type(task))
    |> maybe_put("semantic", semantic_map(task))
    |> maybe_put("ai_hooks", ai_hooks_map(task))
    |> maybe_put("provides", capability_field(task, "provides"))
    |> maybe_put("needs", capability_field(task, "needs"))
    |> maybe_put("success_criteria", non_empty(Task.success_criteria(task)))
    |> maybe_put("evidence_required", non_empty(Task.evidence_required(task)))
    |> maybe_put("actor", normalized_map(Task.actor(task)))
    |> maybe_put("mandate", mandate_map(Task.mandate(task)))
    |> maybe_put("target", target_map(task))
    |> maybe_put("review", review_map(task))
    |> maybe_put("gate", gate_map(task))
    |> empty_to_nil()
  end

  # Keep this raw-map path in sync with the struct path above. The struct path
  # is canonical for live graph tasks; this path preserves persisted/legacy
  # history records that are already decoded into maps.
  def from_task(%{} = task) do
    %{}
    |> maybe_put("kind", stringify(task[:kind] || task["kind"]))
    |> maybe_put("task_type", task[:task_type] || task["task_type"])
    |> maybe_put("semantic", normalized_map(task[:semantic] || task["semantic"]))
    |> maybe_put("ai_hooks", normalized_map(task[:ai_hooks] || task["ai_hooks"]))
    |> maybe_put("provides", normalized_value(task[:provides] || task["provides"]))
    |> maybe_put("needs", normalized_value(task[:needs] || task["needs"]))
    |> maybe_put(
      "success_criteria",
      normalized_value(non_empty(task[:success_criteria] || task["success_criteria"]))
    )
    |> maybe_put(
      "evidence_required",
      normalized_value(non_empty(task[:evidence_required] || task["evidence_required"]))
    )
    |> maybe_put("actor", normalized_map(task[:actor] || task["actor"]))
    |> maybe_put("mandate", mandate_map(task[:mandate] || task["mandate"]))
    |> maybe_put("target", map_target(task))
    |> maybe_put("review", normalized_map(task[:review] || task["review"]))
    |> maybe_put("gate", normalized_map(task[:gate] || task["gate"]))
    |> empty_to_nil()
  end

  @doc "Serializes success criteria results to stable string-keyed maps."
  @spec success_criteria_results([SuccessCriteria.Result.t() | map()] | nil) :: [map()]
  def success_criteria_results(nil), do: []

  def success_criteria_results(results) when is_list(results) do
    Enum.map(results, &success_criteria_result_to_map/1)
  end

  def success_criteria_result_to_map(%SuccessCriteria.Result{} = result) do
    %{
      "index" => result.index,
      "type" => result.type,
      "status" => stringify(result.status),
      "message" => result.message,
      "evidence" => result.evidence,
      "target" => result.target
    }
    |> reject_empty()
  end

  def success_criteria_result_to_map(%{} = result) do
    result
    |> to_json_compatible()
    |> reject_empty()
  end

  @doc "Decodes persisted success criteria result maps."
  @spec success_criteria_results_from_maps([map()] | nil) :: [SuccessCriteria.Result.t()]
  def success_criteria_results_from_maps(nil), do: []

  def success_criteria_results_from_maps(results) when is_list(results) do
    Enum.map(results, &success_criteria_result_from_map/1)
  end

  defp success_criteria_result_from_map(%{} = data) do
    %SuccessCriteria.Result{
      index: data["index"],
      type: data["type"],
      status: parse_status(data["status"]),
      message: data["message"],
      evidence: data["evidence"],
      target: data["target"]
    }
  end

  @doc "Serializes evidence requirement results to stable string-keyed maps."
  @spec evidence_results([EvidenceRequirement.Result.t() | map()] | nil) :: [map()]
  def evidence_results(nil), do: []

  def evidence_results(results) when is_list(results) do
    Enum.map(results, &evidence_result_to_map/1)
  end

  def evidence_result_to_map(%EvidenceRequirement.Result{} = result) do
    %{
      "index" => result.index,
      "type" => result.type,
      "name" => result.name,
      "status" => stringify(result.status),
      "message" => result.message,
      "required" => result.required,
      "evidence_ref" => result.evidence_ref,
      "target" => result.target
    }
    |> reject_empty()
  end

  def evidence_result_to_map(%{} = result) do
    result
    |> to_json_compatible()
    |> reject_empty()
  end

  @doc "Decodes persisted evidence requirement result maps."
  @spec evidence_results_from_maps([map()] | nil) :: [EvidenceRequirement.Result.t()]
  def evidence_results_from_maps(nil), do: []

  def evidence_results_from_maps(results) when is_list(results) do
    Enum.map(results, &evidence_result_from_map/1)
  end

  defp evidence_result_from_map(%{} = data) do
    %EvidenceRequirement.Result{
      index: data["index"],
      type: data["type"],
      name: data["name"],
      status: parse_evidence_status(data["status"]),
      message: data["message"],
      required: data["required"],
      evidence_ref: data["evidence_ref"],
      target: data["target"]
    }
  end

  defp semantic_map(%Task{} = task) do
    if Task.has_semantic?(task), do: Semantic.to_map(Task.semantic(task))
  end

  defp ai_hooks_map(%Task{} = task) do
    if Task.has_ai_hooks?(task), do: AiHooks.to_map(Task.ai_hooks(task))
  end

  defp capability_field(%Task{} = task, field) do
    task
    |> Task.capability()
    |> Capability.to_map()
    |> case do
      nil -> nil
      map -> map[field]
    end
  end

  defp target_map(%Task{} = task) do
    %{}
    |> maybe_put("container", Task.container(task))
    |> maybe_put("workdir", Task.workdir(task))
    |> maybe_put("timeout_seconds", Task.timeout(task))
    |> maybe_put("requires", non_empty(Task.requires(task)))
    |> empty_to_nil()
  end

  defp map_target(%{} = task) do
    %{}
    |> maybe_put("container", task[:container] || task["container"])
    |> maybe_put("workdir", task[:workdir] || task["workdir"])
    |> maybe_put("timeout_seconds", task[:timeout] || task["timeout"])
    |> maybe_put("requires", normalized_value(non_empty(task[:requires] || task["requires"])))
    |> empty_to_nil()
  end

  defp review_map(%Task{} = task) do
    if Task.review?(task) do
      %{}
      |> maybe_put("primitive", Task.primitive(task))
      |> maybe_put("agent", Task.agent(task))
      |> maybe_put("context", non_empty(Task.context(task)))
      |> maybe_put("deterministic", Task.deterministic?(task))
      |> empty_to_nil()
    end
  end

  defp gate_map(%Task{gate: %Gate{} = gate}), do: Gate.to_map(gate)
  defp gate_map(_), do: nil

  defp mandate_map(nil), do: nil

  defp mandate_map(%{} = mandate) do
    mandate
    |> normalized_map()
    |> truncate_mandate_scope()
  end

  defp truncate_mandate_scope(%{"scope" => scope} = mandate) when is_list(scope) do
    if length(scope) > 20 do
      mandate
      |> Map.put("scope", Enum.take(scope, 20))
      |> Map.put("scope_count", length(scope))
    else
      mandate
    end
  end

  defp truncate_mandate_scope(mandate), do: mandate

  defp parse_status(value) when value in ["passed", "failed", "unsupported"] do
    String.to_existing_atom(value)
  end

  defp parse_status(value) when value in [:passed, :failed, :unsupported], do: value
  defp parse_status(_), do: :unknown

  defp parse_evidence_status(value)
       when value in ["satisfied", "missing", "unsupported", "not_evaluated"] do
    String.to_existing_atom(value)
  end

  defp parse_evidence_status(value) when is_atom(value), do: value
  defp parse_evidence_status(_), do: :missing

  defp normalized_map(nil), do: nil
  defp normalized_map(%{} = map), do: map |> to_json_compatible() |> reject_empty()
  defp normalized_map(_), do: nil

  defp normalized_value(nil), do: nil
  defp normalized_value(value), do: to_json_compatible(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, value) when value == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_empty(nil), do: nil
  defp non_empty([]), do: nil
  defp non_empty(value), do: value

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(map), do: map

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] or value == %{} end)
    |> Map.new()
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp to_json_compatible(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), to_json_compatible(value)}
      {key, value} -> {key, to_json_compatible(value)}
    end)
  end

  defp to_json_compatible(list) when is_list(list), do: Enum.map(list, &to_json_compatible/1)
  defp to_json_compatible(value) when is_atom(value), do: Atom.to_string(value)
  defp to_json_compatible(value), do: value
end
