defmodule Sykli.Mandate do
  @moduledoc """
  Validation helpers for v5 task `mandate` declarations.
  """

  @spec parse(term(), :task | :review, String.t(), String.t() | nil) ::
          {:ok, map() | nil} | {:error, term()}
  def parse(nil, _kind, _version, _task_name), do: {:ok, nil}

  def parse(mandate, kind, version, task_name) do
    case validate(mandate, kind, version, task_name) do
      :ok -> {:ok, normalize(mandate)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate(term(), :task | :review, String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def validate(nil, _kind, _version, _task_name), do: :ok

  def validate(_mandate, :review, _version, task_name) do
    {:error, {:mandate_on_review, task_name}}
  end

  def validate(_mandate, _kind, version, task_name) when version != "5" do
    {:error, {:mandate_requires_version_5, task_name, version}}
  end

  def validate(%{"scope" => scope} = mandate, _kind, "5", task_name) do
    with :ok <- validate_scope(scope, task_name),
         :ok <- validate_budget(mandate, task_name),
         :ok <- validate_capabilities(mandate, task_name) do
      validate_no_extra_keys(mandate, ["scope", "budget", "capabilities"], task_name)
    end
  end

  def validate(%{} = _mandate, _kind, "5", task_name) do
    {:error, {:invalid_mandate, task_name, "requires scope"}}
  end

  def validate(_mandate, _kind, "5", task_name) do
    {:error, {:invalid_mandate, task_name, "must be an object"}}
  end

  @spec validate_agent_contract(map() | nil, map() | nil, [map()], [map()], String.t() | nil) ::
          :ok | {:error, term()}
  def validate_agent_contract(%{"kind" => "agent"}, nil, _criteria, _evidence, task_name) do
    {:error, {:agent_requires_mandate, task_name}}
  end

  def validate_agent_contract(%{"kind" => "agent"}, _mandate, [], _evidence, task_name) do
    {:error, {:agent_requires_success_criteria, task_name}}
  end

  def validate_agent_contract(%{"kind" => "agent"}, _mandate, _criteria, [], task_name) do
    {:error, {:agent_requires_evidence_required, task_name}}
  end

  def validate_agent_contract(_actor, _mandate, _criteria, _evidence, _task_name), do: :ok

  @spec format_error(term()) :: String.t()
  def format_error(reason), do: "Error: #{message(reason)}"

  @spec to_error_map(term()) :: map()
  def to_error_map(reason) do
    %{
      type: error_type(reason),
      task: error_task(reason),
      message: message(reason)
    }
  end

  @spec message(term()) :: String.t()
  def message({:mandate_on_review, task_name}) do
    "Review node '#{task_name}' cannot declare mandate"
  end

  def message({:mandate_requires_version_5, task_name, version}) do
    "Task '#{task_name}' declares mandate but pipeline version is #{inspect(version)}, not \"5\""
  end

  def message({:invalid_mandate, task_name, reason}) do
    "Task '#{task_name}' declares invalid mandate: #{reason}"
  end

  def message({:agent_requires_mandate, task_name}) do
    "Task '#{task_name}' declares actor.kind \"agent\" but does not declare mandate"
  end

  def message({:agent_requires_success_criteria, task_name}) do
    "Task '#{task_name}' declares actor.kind \"agent\" but does not declare non-empty success_criteria"
  end

  def message({:agent_requires_evidence_required, task_name}) do
    "Task '#{task_name}' declares actor.kind \"agent\" but does not declare non-empty evidence_required"
  end

  defp validate_scope(scope, task_name) when is_list(scope) and scope != [] do
    if Enum.all?(scope, &(is_binary(&1) and &1 != "")) do
      :ok
    else
      {:error, {:invalid_mandate, task_name, "scope entries must be non-empty strings"}}
    end
  end

  defp validate_scope(_scope, task_name) do
    {:error, {:invalid_mandate, task_name, "scope must be a non-empty array"}}
  end

  defp validate_budget(%{"budget" => budget}, task_name) when is_map(budget) do
    with :ok <- validate_budget_keys(budget, task_name),
         :ok <- validate_positive_integer(budget, "diff_lines", task_name),
         :ok <- validate_positive_integer(budget, "wall_clock_ms", task_name) do
      if map_size(budget) == 0 do
        {:error, {:invalid_mandate, task_name, "budget must not be empty"}}
      else
        :ok
      end
    end
  end

  defp validate_budget(%{"budget" => _budget}, task_name) do
    {:error, {:invalid_mandate, task_name, "budget must be an object"}}
  end

  defp validate_budget(_mandate, _task_name), do: :ok

  defp validate_budget_keys(budget, task_name) do
    validate_no_extra_keys(budget, ["diff_lines", "wall_clock_ms"], task_name, "budget")
  end

  defp validate_positive_integer(map, key, task_name) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value > 0 ->
        :ok

      {:ok, _value} ->
        {:error, {:invalid_mandate, task_name, "budget.#{key} must be a positive integer"}}

      :error ->
        :ok
    end
  end

  defp validate_capabilities(%{"capabilities" => capabilities}, task_name)
       when is_map(capabilities) do
    with :ok <- validate_no_extra_keys(capabilities, ["network"], task_name, "capabilities") do
      case Map.fetch(capabilities, "network") do
        {:ok, value} when is_boolean(value) ->
          :ok

        {:ok, _value} ->
          {:error, {:invalid_mandate, task_name, "capabilities.network must be a boolean"}}

        :error ->
          :ok
      end
    end
  end

  defp validate_capabilities(%{"capabilities" => _capabilities}, task_name) do
    {:error, {:invalid_mandate, task_name, "capabilities must be an object"}}
  end

  defp validate_capabilities(_mandate, _task_name), do: :ok

  defp validate_no_extra_keys(map, allowed_keys, task_name) do
    validate_no_extra_keys(map, allowed_keys, task_name, nil)
  end

  defp validate_no_extra_keys(map, allowed_keys, task_name, prefix) do
    extra_keys = Map.keys(map) -- allowed_keys

    if extra_keys == [] do
      :ok
    else
      path = if prefix, do: "#{prefix} has", else: "has"

      {:error,
       {:invalid_mandate, task_name, "#{path} unknown keys: #{Enum.join(extra_keys, ", ")}"}}
    end
  end

  defp normalize(mandate) do
    mandate
    |> Map.take(["scope", "budget", "capabilities"])
    |> reject_empty()
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
    |> Map.new()
  end

  defp error_type({type, _task_name}) when is_atom(type), do: type
  defp error_type({type, _task_name, _detail}) when is_atom(type), do: type

  defp error_task({_type, task_name}), do: task_name
  defp error_task({_type, task_name, _detail}), do: task_name
end
