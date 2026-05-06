defmodule Sykli.SuccessCriteria do
  @moduledoc """
  Shared validation for success_criteria metadata in the semantic pipeline contract.

  This module validates declared criteria only. It does not evaluate them during
  task execution.
  """

  @types ~w(exit_code file_exists file_non_empty)

  @spec types() :: [String.t()]
  def types, do: @types

  @spec parse(term(), :task | :review, String.t(), String.t() | nil) ::
          {:ok, [map()]} | {:error, term()}
  def parse(nil, _kind, _version, _task_name), do: {:ok, []}

  def parse(criteria, kind, version, task_name) do
    case validate(criteria, kind, version, task_name) do
      :ok -> {:ok, normalize(criteria)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate(term(), :task | :review, String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def validate(nil, _kind, _version, _task_name), do: :ok

  def validate(_criteria, :review, _version, task_name) do
    {:error, {:success_criteria_on_review, task_name}}
  end

  def validate(_criteria, _kind, version, task_name) when version != "3" do
    {:error, {:success_criteria_requires_version_3, task_name, version}}
  end

  def validate(criteria, _kind, "3", task_name) when is_list(criteria) do
    with :ok <- validate_items(criteria, task_name),
         :ok <- validate_single_exit_code(criteria, task_name) do
      :ok
    end
  end

  def validate(_criteria, _kind, "3", task_name) do
    {:error, {:invalid_success_criteria, task_name, "must be an array"}}
  end

  @spec format_error(term()) :: String.t()
  def format_error({:success_criteria_on_review, task_name}) do
    "Error: Review node '#{task_name}' cannot declare success_criteria"
  end

  def format_error({:success_criteria_requires_version_3, task_name, version}) do
    "Error: Task '#{task_name}' declares success_criteria but pipeline version is #{inspect(version)}, not \"3\""
  end

  def format_error({:invalid_success_criteria, task_name, reason}) do
    "Error: Task '#{task_name}' declares invalid success_criteria: #{reason}"
  end

  def format_error({:unknown_success_criterion_type, task_name, type}) do
    "Error: Task '#{task_name}' declares unknown success_criteria type #{inspect(type)}"
  end

  def format_error({:duplicate_exit_code_criteria, task_name}) do
    "Error: Task '#{task_name}' declares multiple exit_code success criteria"
  end

  defp validate_items(criteria, task_name) do
    Enum.reduce_while(criteria, :ok, fn criterion, :ok ->
      case validate_item(criterion, task_name) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_item(%{"type" => "exit_code"} = criterion, task_name) do
    case Map.fetch(criterion, "equals") do
      {:ok, value} when is_integer(value) ->
        validate_no_extra_keys(criterion, ["type", "equals"], task_name, "exit_code")

      {:ok, _value} ->
        {:error, {:invalid_success_criteria, task_name, "exit_code.equals must be an integer"}}

      :error ->
        {:error, {:invalid_success_criteria, task_name, "exit_code requires equals"}}
    end
  end

  defp validate_item(%{"type" => type} = criterion, task_name)
       when type in ["file_exists", "file_non_empty"] do
    case Map.fetch(criterion, "path") do
      {:ok, path} when is_binary(path) and path != "" ->
        validate_no_extra_keys(criterion, ["type", "path"], task_name, type)

      {:ok, _path} ->
        {:error,
         {:invalid_success_criteria, task_name, "#{type}.path must be a non-empty string"}}

      :error ->
        {:error, {:invalid_success_criteria, task_name, "#{type} requires path"}}
    end
  end

  defp validate_item(%{"type" => type}, task_name) do
    {:error, {:unknown_success_criterion_type, task_name, type}}
  end

  defp validate_item(%{}, task_name) do
    {:error, {:invalid_success_criteria, task_name, "criterion requires type"}}
  end

  defp validate_item(_criterion, task_name) do
    {:error, {:invalid_success_criteria, task_name, "each criterion must be an object"}}
  end

  defp validate_single_exit_code(criteria, task_name) do
    count = Enum.count(criteria, &match?(%{"type" => "exit_code"}, &1))

    if count > 1 do
      {:error, {:duplicate_exit_code_criteria, task_name}}
    else
      :ok
    end
  end

  defp validate_no_extra_keys(criterion, allowed_keys, task_name, type) do
    extra_keys = Map.keys(criterion) -- allowed_keys

    if extra_keys == [] do
      :ok
    else
      {:error,
       {:invalid_success_criteria, task_name,
        "#{type} has unknown keys: #{Enum.join(extra_keys, ", ")}"}}
    end
  end

  defp normalize(criteria) do
    Enum.map(criteria, fn
      %{"type" => "exit_code", "equals" => equals} ->
        %{"type" => "exit_code", "equals" => equals}

      %{"type" => type, "path" => path} ->
        %{"type" => type, "path" => path}
    end)
  end
end
