defmodule Sykli.Services.CapabilityResolver do
  @moduledoc """
  Resolves capability-based dependencies (provides/needs).

  Builds a registry of capability_name -> provider_task_name,
  validates uniqueness and completeness, then adds concrete
  depends_on entries and SYKLI_CAP_* env vars.

  ## How it works

  1. Scan all tasks for `provides` declarations
  2. Build a registry: capability name -> {provider task, optional value}
  3. Validate:
     - Capability names match [a-z][a-z0-9_-]*
     - No task provides and needs the same capability
     - Matrix tasks cannot provide capabilities (ambiguous)
     - No duplicate providers for the same capability
     - All needed capabilities are provided by some task
  4. Inject:
     - Add dependency from needer to provider
     - Set SYKLI_CAP_{NAME} env var if the provider declared a value
  """

  alias Sykli.Error

  @capability_name_regex ~r/^[a-z][a-z0-9_-]*$/

  @doc """
  Resolve all provides/needs in the graph.

  Returns {:ok, updated_graph} or {:error, error}.
  """
  @spec resolve(map()) :: {:ok, map()} | {:error, Sykli.Error.t()}
  def resolve(graph) do
    with :ok <- validate_capability_names(graph),
         :ok <- validate_no_self_provide_need(graph),
         :ok <- validate_no_matrix_provides(graph),
         {:ok, registry} <- build_registry(graph),
         :ok <- validate_all_needs_met(graph, registry) do
      {:ok, inject_dependencies(graph, registry)}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VALIDATION
  # ─────────────────────────────────────────────────────────────────────────────

  defp validate_capability_names(graph) do
    Enum.reduce_while(graph, :ok, fn {_name, task}, :ok ->
      cap = task.capability

      if is_nil(cap) do
        {:cont, :ok}
      else
        validate_task_cap_names(task.name, cap)
      end
    end)
  end

  defp validate_task_cap_names(task_name, cap) do
    invalid_provides =
      Enum.reject(cap.provides, fn p -> Regex.match?(@capability_name_regex, p.name) end)

    invalid_needs =
      Enum.reject(cap.needs, fn n -> Regex.match?(@capability_name_regex, n) end)

    cond do
      invalid_provides != [] ->
        name = hd(invalid_provides).name

        {:halt,
         {:error,
          Error.internal(
            "task '#{task_name}': invalid capability name '#{name}' (must match [a-z][a-z0-9_-]*)"
          )
          |> Error.add_hint(
            "capability names must start with lowercase letter and contain only lowercase letters, digits, hyphens, underscores"
          )}}

      invalid_needs != [] ->
        name = hd(invalid_needs)

        {:halt,
         {:error,
          Error.internal(
            "task '#{task_name}': invalid capability name '#{name}' (must match [a-z][a-z0-9_-]*)"
          )
          |> Error.add_hint(
            "capability names must start with lowercase letter and contain only lowercase letters, digits, hyphens, underscores"
          )}}

      true ->
        {:cont, :ok}
    end
  end

  defp validate_no_self_provide_need(graph) do
    Enum.reduce_while(graph, :ok, fn {_name, task}, :ok ->
      cap = task.capability

      if is_nil(cap) do
        {:cont, :ok}
      else
        provided_names = Enum.map(cap.provides, & &1.name) |> MapSet.new()
        needed_names = MapSet.new(cap.needs)
        overlap = MapSet.intersection(provided_names, needed_names)

        if MapSet.size(overlap) > 0 do
          cap_name = Enum.at(MapSet.to_list(overlap), 0)

          {:halt,
           {:error,
            Error.internal(
              "task '#{task.name}' both provides and needs capability '#{cap_name}'"
            )
            |> Error.add_hint("a task cannot provide and need the same capability")}}
        else
          {:cont, :ok}
        end
      end
    end)
  end

  defp validate_no_matrix_provides(graph) do
    Enum.reduce_while(graph, :ok, fn {_name, task}, :ok ->
      cap = task.capability
      has_provides = cap != nil and cap.provides != []
      has_matrix = task.matrix != nil and map_size(task.matrix) > 0

      if has_provides and has_matrix do
        {:halt,
         {:error,
          Error.internal(
            "task '#{task.name}' uses matrix and provides capabilities, which would be ambiguous"
          )
          |> Error.add_hint("remove either matrix or provides from this task")}}
      else
        {:cont, :ok}
      end
    end)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # REGISTRY
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_registry(graph) do
    Enum.reduce_while(graph, {:ok, %{}}, fn {_name, task}, {:ok, reg} ->
      cap = task.capability

      if is_nil(cap) or cap.provides == [] do
        {:cont, {:ok, reg}}
      else
        case register_provides(task.name, cap.provides, reg) do
          {:ok, new_reg} -> {:cont, {:ok, new_reg}}
          {:error, _} = err -> {:halt, err}
        end
      end
    end)
  end

  defp register_provides(_task_name, [], reg), do: {:ok, reg}

  defp register_provides(task_name, [provide | rest], reg) do
    case Map.get(reg, provide.name) do
      nil ->
        new_reg = Map.put(reg, provide.name, {task_name, provide.value})
        register_provides(task_name, rest, new_reg)

      {existing_task, _} ->
        {:error,
         Error.internal(
           "capability '#{provide.name}' is provided by both '#{existing_task}' and '#{task_name}'"
         )
         |> Error.add_hint("each capability must be provided by exactly one task")}
    end
  end

  defp validate_all_needs_met(graph, registry) do
    Enum.reduce_while(graph, :ok, fn {_name, task}, :ok ->
      cap = task.capability

      if is_nil(cap) or cap.needs == [] do
        {:cont, :ok}
      else
        unmet = Enum.reject(cap.needs, fn need -> Map.has_key?(registry, need) end)

        if unmet != [] do
          need_name = hd(unmet)
          available = Map.keys(registry) |> Enum.join(", ")

          hint =
            if available == "",
              do: "no capabilities are provided by any task",
              else: "available capabilities: #{available}"

          {:halt,
           {:error,
            Error.internal(
              "task '#{task.name}' needs capability '#{need_name}' but no task provides it"
            )
            |> Error.add_hint(hint)}}
        else
          {:cont, :ok}
        end
      end
    end)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # INJECTION
  # ─────────────────────────────────────────────────────────────────────────────

  defp inject_dependencies(graph, registry) do
    graph
    |> Enum.map(fn {name, task} ->
      cap = task.capability

      if is_nil(cap) or cap.needs == [] do
        {name, task}
      else
        # Add dependency on provider tasks and inject env vars
        {new_deps, new_env} =
          Enum.reduce(cap.needs, {task.depends_on || [], task.env || %{}}, fn need,
                                                                             {deps, env} ->
            {provider_task, value} = Map.fetch!(registry, need)

            # Add dependency (deduplicated)
            new_deps = if provider_task in deps, do: deps, else: deps ++ [provider_task]

            # Inject SYKLI_CAP_* env var if value is present
            new_env =
              if value do
                env_key = "SYKLI_CAP_#{String.upcase(String.replace(need, "-", "_"))}"
                Map.put(env, env_key, value)
              else
                env
              end

            {new_deps, new_env}
          end)

        {name, %{task | depends_on: new_deps, env: new_env}}
      end
    end)
    |> Map.new()
  end
end
