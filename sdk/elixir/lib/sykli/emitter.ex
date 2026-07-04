defmodule Sykli.Emitter do
  @moduledoc """
  Validates pipelines and emits JSON output.
  """

  require Logger

  # ============================================================================
  # VALIDATION
  # ============================================================================

  @doc "Validates a pipeline, raises on errors."
  def validate!(pipeline) do
    task_names = MapSet.new(pipeline.tasks, & &1.name)

    # Check for duplicate task names
    if MapSet.size(task_names) != length(pipeline.tasks) do
      Logger.error("duplicate task names detected")
      raise "duplicate task names detected"
    end

    # Check all non-gate, non-review tasks have commands
    Enum.each(pipeline.tasks, fn task ->
      cond do
        task.kind == :review and not is_nil(task.task_type) ->
          Logger.error("review cannot declare task_type", review: task.name)
          raise "review #{inspect(task.name)} cannot declare task_type"

        task.kind != :review and not is_nil(task.task_type) and
            not Sykli.Task.valid_task_type?(task.task_type) ->
          Logger.error("invalid task_type", task: task.name, task_type: inspect(task.task_type))
          raise "task #{inspect(task.name)} has invalid task_type #{inspect(task.task_type)}"

        task.kind == :review and task.success_criteria != [] ->
          Logger.error("review cannot declare success_criteria", review: task.name)
          raise "review #{inspect(task.name)} cannot declare success_criteria"

        task.kind == :review and task.evidence_required != [] ->
          Logger.error("review cannot declare evidence_required", review: task.name)
          raise "review #{inspect(task.name)} cannot declare evidence_required"

        task.kind == :review and not is_nil(task.actor) ->
          Logger.error("review cannot declare actor", review: task.name)
          raise "review #{inspect(task.name)} cannot declare actor"

        task.kind == :review and not is_nil(task.mandate) ->
          Logger.error("review cannot declare mandate", review: task.name)
          raise "review #{inspect(task.name)} cannot declare mandate"

        task.kind != :review and not valid_success_criteria?(task.success_criteria) ->
          Logger.error("invalid success_criteria", task: task.name)
          raise "task #{inspect(task.name)} has invalid success_criteria"

        task.kind != :review and not valid_evidence_required?(task.evidence_required) ->
          Logger.error("invalid evidence_required", task: task.name)
          raise "task #{inspect(task.name)} has invalid evidence_required"

        task.kind != :review and not valid_actor?(task.actor) ->
          Logger.error("invalid actor", task: task.name)
          raise "task #{inspect(task.name)} has invalid actor"

        task.kind != :review and not valid_mandate?(task.mandate) ->
          Logger.error("invalid mandate", task: task.name)
          raise "task #{inspect(task.name)} has invalid mandate"

        task.kind != :review and agent_missing_field(task) ->
          missing = agent_missing_field(task)
          Logger.error("agent actor missing #{missing}", task: task.name)

          raise "task #{inspect(task.name)} declares actor.kind \"agent\" but does not declare #{missing}"

        task.kind == :review and (is_nil(task.primitive) or task.primitive == "") ->
          Logger.error("review has no primitive", review: task.name)
          raise "review #{inspect(task.name)} has no primitive"

        task.kind != :review and is_nil(task.gate) and
            (is_nil(task.command) or task.command == "") ->
          Logger.error("task has no command", task: task.name)
          raise "task #{inspect(task.name)} has no command"

        true ->
          :ok
      end
    end)

    # Check dependencies exist with suggestions
    Enum.each(pipeline.tasks, fn task ->
      Enum.each(task.depends_on, fn dep ->
        unless MapSet.member?(task_names, dep) do
          suggestion = suggest_task_name(dep, MapSet.to_list(task_names))
          message = "task #{inspect(task.name)} depends on unknown task #{inspect(dep)}"

          message =
            if suggestion, do: message <> " (did you mean #{inspect(suggestion)}?)", else: message

          Logger.error("unknown dependency", task: task.name, dependency: dep)
          raise message
        end
      end)
    end)

    # Check for cycles
    case detect_cycle(pipeline.tasks) do
      nil ->
        :ok

      cycle ->
        Logger.error("dependency cycle detected", cycle: cycle)
        raise "dependency cycle detected: #{Enum.join(cycle, " -> ")}"
    end

    # Validate K8s options
    Enum.each(pipeline.tasks, fn task ->
      if task.k8s do
        case Sykli.K8s.validate(task.k8s) do
          {:ok, _} -> :ok
          {:error, [first | _]} -> raise first
        end
      end
    end)

    # Validate Vault secret paths
    Enum.each(pipeline.tasks, fn task ->
      Enum.each(task.secret_refs, fn ref ->
        if ref.source == :vault do
          validate_vault_path!(task.name, ref.key)
        end
      end)
    end)

    Logger.debug("pipeline validated", tasks: length(pipeline.tasks))
    pipeline
  end

  # Suggest similar task names using Jaro-Winkler distance
  defp suggest_task_name(unknown, known_names) do
    known_names
    |> Enum.map(fn name -> {name, String.jaro_distance(unknown, name)} end)
    |> Enum.filter(fn {_, score} -> score >= 0.8 end)
    |> Enum.max_by(fn {_, score} -> score end, fn -> nil end)
    |> case do
      {name, _score} -> name
      nil -> nil
    end
  end

  # Validate Vault path format: path/to/secret#field
  defp validate_vault_path!(task_name, path) do
    unless String.contains?(path, "#") do
      raise """
      task #{inspect(task_name)}: invalid Vault path #{inspect(path)}
      Expected format: "path/to/secret#field" (e.g., "secret/data/db#password")
      """
    end
  end

  # ============================================================================
  # CYCLE DETECTION (3-color DFS)
  # ============================================================================

  defp detect_cycle(tasks) do
    deps = Map.new(tasks, fn t -> {t.name, t.depends_on} end)
    names = Map.keys(deps)

    Enum.reduce_while(names, {%{}, nil}, fn name, {visited, _} ->
      case dfs_cycle(name, deps, visited, []) do
        {:cycle, path} -> {:halt, {visited, path}}
        {:ok, new_visited} -> {:cont, {new_visited, nil}}
      end
    end)
    |> elem(1)
  end

  defp dfs_cycle(node, deps, visited, path) do
    case Map.get(visited, node) do
      :done ->
        {:ok, visited}

      :visiting ->
        cycle_start = Enum.find_index(path, &(&1 == node))
        cycle = Enum.slice(path, cycle_start..-1//1) ++ [node]
        {:cycle, cycle}

      nil ->
        visited = Map.put(visited, node, :visiting)
        path = path ++ [node]

        result =
          Enum.reduce_while(Map.get(deps, node, []), {:ok, visited}, fn dep, {:ok, v} ->
            case dfs_cycle(dep, deps, v, path) do
              {:cycle, _} = cycle -> {:halt, cycle}
              {:ok, new_v} -> {:cont, {:ok, new_v}}
            end
          end)

        case result do
          {:cycle, _} = cycle -> cycle
          {:ok, visited} -> {:ok, Map.put(visited, node, :done)}
        end
    end
  end

  # ============================================================================
  # JSON SERIALIZATION
  # ============================================================================

  @doc "Converts pipeline to JSON string."
  def to_json(pipeline) do
    has_v2_features =
      map_size(pipeline.resources) > 0 or
        Enum.any?(pipeline.tasks, fn t ->
          t.container != nil or length(t.mounts) > 0
        end)

    has_v3_features =
      Enum.any?(pipeline.tasks, &(!is_nil(&1.task_type) or &1.success_criteria != []))

    has_v4_features =
      Enum.any?(pipeline.tasks, &(&1.evidence_required != []))

    has_v5_features =
      Enum.any?(pipeline.tasks, &(!is_nil(&1.actor) or !is_nil(&1.mandate)))

    version =
      cond do
        has_v5_features -> "5"
        has_v4_features -> "4"
        has_v3_features -> "3"
        has_v2_features -> "2"
        true -> "1"
      end

    Logger.debug("emitting pipeline", version: version, tasks: length(pipeline.tasks))

    output = %{
      version: version,
      tasks: Enum.map(pipeline.tasks, &task_to_json/1)
    }

    output =
      if has_v2_features and map_size(pipeline.resources) > 0 do
        Map.put(output, :resources, resources_to_json(pipeline.resources))
      else
        output
      end

    Jason.encode!(output)
  end

  defp task_to_json(task) do
    if task.kind == :review do
      review_to_json(task)
    else
      regular_task_to_json(task)
    end
  end

  defp review_to_json(task) do
    %{
      name: task.name,
      kind: "review",
      primitive: task.primitive,
      deterministic: task.deterministic
    }
    |> maybe_put(:agent, task.agent)
    |> maybe_put(:context, non_empty(task.context))
    |> maybe_put(:inputs, non_empty(task.inputs))
    |> maybe_put(:depends_on, non_empty(task.depends_on))
  end

  defp regular_task_to_json(task) do
    # Use when_cond if set, otherwise use condition string
    condition =
      case task.when_cond do
        %Sykli.Condition{expr: expr} when expr != "" -> expr
        _ -> task.condition
      end

    %{name: task.name}
    |> maybe_put(:task_type, if(task.task_type, do: Atom.to_string(task.task_type), else: nil))
    |> maybe_put(
      :success_criteria,
      non_empty_list(task.success_criteria, &success_criterion_to_json/1)
    )
    |> maybe_put(:evidence_required, non_empty_list(task.evidence_required, & &1))
    |> maybe_put(:actor, actor_to_json(task.actor))
    |> maybe_put(:mandate, mandate_to_json(task.mandate))
    |> maybe_put(:command, task.command)
    |> maybe_put(:container, task.container)
    |> maybe_put(:workdir, task.workdir)
    |> maybe_put(:env, non_empty_map(task.env))
    |> maybe_put(:mounts, non_empty_list(task.mounts, &mount_to_json/1))
    |> maybe_put(:inputs, non_empty(task.inputs))
    |> maybe_put(:outputs, non_empty_map(task.outputs))
    |> maybe_put(:depends_on, non_empty(task.depends_on))
    |> maybe_put(:task_inputs, non_empty_list(task.task_inputs, &task_input_to_json/1))
    |> maybe_put(:when, condition)
    |> maybe_put(:secrets, non_empty(task.secrets))
    |> maybe_put(:secret_refs, non_empty_list(task.secret_refs, &secret_ref_to_json/1))
    |> maybe_put(:matrix, non_empty_map(task.matrix))
    |> maybe_put(:services, non_empty_list(task.services, &service_to_json/1))
    |> maybe_put(:retry, task.retry)
    |> maybe_put(:timeout, task.timeout)
    |> maybe_put(:k8s, if(task.k8s, do: Sykli.K8s.to_json(task.k8s), else: nil))
    |> maybe_put(:requires, non_empty(task.requires))
    |> maybe_put(:provides, non_empty_list(task.provides, &provide_to_json/1))
    |> maybe_put(:needs, non_empty(task.needs))
    |> maybe_put(:semantic, semantic_to_json(task.semantic))
    |> maybe_put(:ai_hooks, ai_hooks_to_json(task.ai_hooks))
    |> maybe_put(:gate, gate_to_json(task.gate))
    |> maybe_put(:verify, task.verify)
  end

  defp gate_to_json(nil), do: nil

  defp gate_to_json(gate) do
    %{strategy: gate.strategy}
    |> maybe_put(:timeout, gate.timeout)
    |> maybe_put(:message, gate.message)
    |> maybe_put(:env_var, gate.env_var)
    |> maybe_put(:file_path, gate.file_path)
  end

  defp actor_to_json(nil), do: nil

  defp actor_to_json(actor) do
    Map.new(actor, fn
      {:kind, kind} -> {:kind, Atom.to_string(kind)}
      {key, value} -> {key, value}
    end)
  end

  defp mandate_to_json(nil), do: nil

  defp mandate_to_json(mandate) do
    %{scope: mandate.scope}
    |> maybe_put(:budget, Map.get(mandate, :budget))
    |> maybe_put(:capabilities, Map.get(mandate, :capabilities))
  end

  defp valid_actor?(nil), do: true

  defp valid_actor?(%{kind: kind} = actor) do
    Sykli.Task.valid_actor_kind?(kind) and
      (not Map.has_key?(actor, :id) or (is_binary(actor.id) and actor.id != ""))
  end

  defp valid_actor?(_), do: false

  defp valid_mandate?(nil), do: true

  defp valid_mandate?(%{scope: scope} = mandate) when is_list(scope) and scope != [] do
    Enum.all?(scope, &(is_binary(&1) and &1 != "")) and
      valid_mandate_budget?(Map.get(mandate, :budget)) and
      valid_mandate_capabilities?(Map.get(mandate, :capabilities))
  end

  defp valid_mandate?(_), do: false

  defp valid_mandate_budget?(nil), do: true

  defp valid_mandate_budget?(budget) when is_map(budget) and map_size(budget) > 0 do
    Enum.all?(budget, fn
      {key, value} when key in [:diff_lines, :wall_clock_ms] -> is_integer(value) and value > 0
      _ -> false
    end)
  end

  defp valid_mandate_budget?(_), do: false

  defp valid_mandate_capabilities?(nil), do: true

  defp valid_mandate_capabilities?(%{network: value}) when is_boolean(value), do: true
  defp valid_mandate_capabilities?(capabilities), do: capabilities == %{}

  defp agent_missing_field(%{actor: %{kind: :agent}} = task) do
    cond do
      is_nil(task.mandate) -> "mandate"
      task.success_criteria == [] -> "success_criteria"
      task.evidence_required == [] -> "evidence_required"
      true -> nil
    end
  end

  defp agent_missing_field(_task), do: nil

  defp valid_success_criteria?(criteria) when is_list(criteria) do
    exit_code_count = Enum.count(criteria, &criterion_type?(&1, "exit_code"))
    exit_code_count <= 1 and Enum.all?(criteria, &valid_success_criterion?/1)
  end

  defp valid_success_criteria?(_), do: false

  defp valid_evidence_required?(requirements) when is_list(requirements) do
    Enum.all?(requirements, &valid_evidence_requirement?/1)
  end

  defp valid_evidence_required?(_), do: false

  defp valid_evidence_requirement?(
         %{
           "type" => "file",
           "name" => name,
           "ref_pattern" => ref_pattern
         } = req
       ) do
    is_binary(name) and name != "" and is_binary(ref_pattern) and ref_pattern != "" and
      Map.get(req, "predicate", "exists") in ["exists", "non_empty"]
  end

  defp valid_evidence_requirement?(%{"type" => type, "name" => name})
       when type in [
              "log",
              "attestation",
              "occurrence",
              "metric",
              "test_report",
              "artifact_ref",
              "custom"
            ],
       do: is_binary(name) and name != ""

  defp valid_evidence_requirement?(_), do: false

  defp valid_success_criterion?(%{type: "exit_code", equals: equals}), do: is_integer(equals)

  defp valid_success_criterion?(%{type: type, path: path})
       when type in ["file_exists", "file_non_empty"],
       do: is_binary(path) and path != ""

  defp valid_success_criterion?(%{"type" => "exit_code", "equals" => equals}),
    do: is_integer(equals)

  defp valid_success_criterion?(%{"type" => type, "path" => path})
       when type in ["file_exists", "file_non_empty"],
       do: is_binary(path) and path != ""

  defp valid_success_criterion?(_), do: false

  defp criterion_type?(%{type: type}, expected), do: type == expected
  defp criterion_type?(%{"type" => type}, expected), do: type == expected
  defp criterion_type?(_, _), do: false

  defp success_criterion_to_json(%{type: "exit_code", equals: equals}) do
    %{type: "exit_code", equals: equals}
  end

  defp success_criterion_to_json(%{type: "file_exists", path: path}) do
    %{type: "file_exists", path: path}
  end

  defp success_criterion_to_json(%{type: "file_non_empty", path: path}) do
    %{type: "file_non_empty", path: path}
  end

  defp success_criterion_to_json(%{"type" => "exit_code", "equals" => equals}) do
    %{type: "exit_code", equals: equals}
  end

  defp success_criterion_to_json(%{"type" => "file_exists", "path" => path}) do
    %{type: "file_exists", path: path}
  end

  defp success_criterion_to_json(%{"type" => "file_non_empty", "path" => path}) do
    %{type: "file_non_empty", path: path}
  end

  defp semantic_to_json(nil), do: nil

  defp semantic_to_json(semantic) do
    %{}
    |> maybe_put(:covers, non_empty(semantic.covers))
    |> maybe_put(:intent, semantic.intent)
    |> maybe_put(
      :criticality,
      if(semantic.criticality, do: Atom.to_string(semantic.criticality), else: nil)
    )
    |> case do
      map when map_size(map) == 0 -> nil
      map -> map
    end
  end

  defp ai_hooks_to_json(nil), do: nil

  defp ai_hooks_to_json(ai_hooks) do
    %{}
    |> maybe_put(:on_fail, if(ai_hooks.on_fail, do: Atom.to_string(ai_hooks.on_fail), else: nil))
    |> maybe_put(:select, if(ai_hooks.select, do: Atom.to_string(ai_hooks.select), else: nil))
    |> case do
      map when map_size(map) == 0 -> nil
      map -> map
    end
  end

  defp provide_to_json(%{name: name, value: nil}), do: %{name: name}
  defp provide_to_json(%{name: name, value: value}), do: %{name: name, value: value}
  defp provide_to_json(%{name: name}), do: %{name: name}

  defp secret_ref_to_json(ref) do
    source =
      case ref.source do
        :env -> "env"
        :file -> "file"
        :vault -> "vault"
      end

    %{name: ref.name, source: source, key: ref.key}
  end

  defp mount_to_json(mount) do
    %{resource: mount.resource, path: mount.path, type: Atom.to_string(mount.type)}
  end

  defp task_input_to_json(ti) do
    %{from_task: ti.from_task, output: ti.output, dest: ti.dest}
  end

  defp service_to_json(svc) do
    %{image: svc.image, name: svc.name}
  end

  defp resources_to_json(resources) do
    Map.new(resources, fn {name, r} ->
      json =
        case r.type do
          :directory ->
            %{type: "directory", path: r.path}
            |> maybe_put(:globs, non_empty(r.globs))

          :cache ->
            %{type: "cache", name: r.name}
        end

      {name, json}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp non_empty_map(map) when map_size(map) == 0, do: nil
  defp non_empty_map(map), do: map

  defp non_empty_list([], _), do: nil
  defp non_empty_list(list, mapper), do: Enum.map(list, mapper)
end
