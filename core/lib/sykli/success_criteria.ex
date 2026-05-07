defmodule Sykli.SuccessCriteria do
  @moduledoc """
  Shared validation and result helpers for success_criteria in the semantic
  pipeline contract.
  """

  defmodule Result do
    @moduledoc """
    Result of evaluating one success criterion in a target-owned execution
    context.
    """

    @enforce_keys [:index, :type, :status, :message]
    defstruct [:index, :type, :status, :message, :evidence, :target]

    @type status :: :passed | :failed | :unsupported

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            type: String.t(),
            status: status(),
            message: String.t(),
            evidence: map() | nil,
            target: String.t() | nil
          }
  end

  @types ~w(exit_code file_exists file_non_empty)
  @exit_code_range 0..255

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
  def format_error(reason), do: "Error: #{message(reason)}"

  @spec passed?(Result.t()) :: boolean()
  def passed?(%Result{status: :passed}), do: true
  def passed?(%Result{}), do: false

  @spec failures([Result.t()]) :: [Result.t()]
  def failures(results) do
    Enum.reject(results, &passed?/1)
  end

  @spec unsupported_results(
          [map()],
          String.t() | nil,
          String.t()
        ) :: [Result.t()]
  def unsupported_results(criteria, target_name, message) do
    criteria
    |> Enum.with_index()
    |> Enum.map(fn {criterion, index} ->
      %Result{
        index: index,
        type: Map.get(criterion, "type", "unknown"),
        status: :unsupported,
        message: message,
        evidence: criterion,
        target: target_name
      }
    end)
  end

  @spec message(term()) :: String.t()
  def message({:success_criteria_on_review, task_name}) do
    "Review node '#{task_name}' cannot declare success_criteria"
  end

  def message({:success_criteria_requires_version_3, task_name, version}) do
    "Task '#{task_name}' declares success_criteria but pipeline version is #{inspect(version)}, not \"3\""
  end

  def message({:invalid_success_criteria, task_name, reason}) do
    "Task '#{task_name}' declares invalid success_criteria: #{reason}"
  end

  def message({:unknown_success_criterion_type, task_name, type}) do
    "Task '#{task_name}' declares unknown success_criteria type #{inspect(type)}"
  end

  def message({:duplicate_exit_code_criteria, task_name}) do
    "Task '#{task_name}' declares multiple exit_code success criteria"
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
      {:ok, value} when is_integer(value) and value in @exit_code_range ->
        validate_no_extra_keys(criterion, ["type", "equals"], task_name, "exit_code")

      {:ok, value} when is_integer(value) ->
        {:error,
         {:invalid_success_criteria, task_name, "exit_code.equals must be between 0 and 255"}}

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

  # Canonicalize validated criteria to the wire key set. This keeps parse output
  # stable if a future caller bypasses schema validation.
  defp normalize(criteria) do
    Enum.map(criteria, fn
      %{"type" => "exit_code", "equals" => equals} ->
        %{"type" => "exit_code", "equals" => equals}

      %{"type" => type, "path" => path} ->
        %{"type" => type, "path" => path}
    end)
  end
end
