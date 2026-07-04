defmodule Sykli.EvidenceRequirement do
  @moduledoc """
  Validation and result helpers for `evidence_required`.

  Evidence requirements are contract-level proof requirements. V1 evaluates
  local file references on targets that can prove their own filesystem context;
  other declared evidence types are preserved and reported as unsupported until
  Sykli has a concrete evidence source for them.
  """

  defmodule Result do
    @moduledoc "Result of evaluating one evidence requirement."

    @enforce_keys [:index, :type, :name, :status, :message]
    defstruct [:index, :type, :name, :status, :message, :required, :evidence_ref, :target]

    @type status :: :satisfied | :missing | :unsupported | :not_evaluated

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            type: String.t(),
            name: String.t(),
            status: status(),
            message: String.t(),
            required: boolean() | nil,
            evidence_ref: map() | nil,
            target: String.t() | nil
          }
  end

  @types ~w(file log attestation occurrence metric test_report artifact_ref custom)
  @visibilities ~w(local run_history occurrence coordinator_ref)
  @predicates ~w(exists non_empty)

  @spec types() :: [String.t()]
  def types, do: @types

  @spec parse(term(), :task | :review, String.t(), String.t() | nil) ::
          {:ok, [map()]} | {:error, term()}
  def parse(nil, _kind, _version, _task_name), do: {:ok, []}

  def parse(requirements, kind, version, task_name) do
    case validate(requirements, kind, version, task_name) do
      :ok -> {:ok, normalize(requirements)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate(term(), :task | :review, String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def validate(nil, _kind, _version, _task_name), do: :ok

  def validate(_requirements, :review, _version, task_name) do
    {:error, {:evidence_required_on_review, task_name}}
  end

  def validate(_requirements, _kind, version, task_name) when version not in ["4", "5"] do
    {:error, {:evidence_required_requires_version_4, task_name, version}}
  end

  def validate(requirements, _kind, version, task_name)
      when is_list(requirements) and version in ["4", "5"] do
    validate_items(requirements, task_name)
  end

  def validate(_requirements, _kind, version, task_name) when version in ["4", "5"] do
    {:error, {:invalid_evidence_required, task_name, "must be an array"}}
  end

  @spec failures([Result.t()]) :: [Result.t()]
  def failures(results) do
    Enum.reject(results, fn result ->
      result.status == :satisfied or result.required == false
    end)
  end

  @spec unsupported_results([map()], String.t() | nil, String.t()) :: [Result.t()]
  def unsupported_results(requirements, target_name, message) do
    requirements
    |> Enum.with_index()
    |> Enum.map(fn {requirement, index} ->
      %Result{
        index: index,
        type: Map.get(requirement, "type", "unknown"),
        name: Map.get(requirement, "name", "unknown"),
        status: :unsupported,
        message: message,
        required: Map.get(requirement, "required", true),
        evidence_ref: requirement,
        target: target_name
      }
    end)
  end

  @spec format_error(term()) :: String.t()
  def format_error(reason), do: "Error: #{message(reason)}"

  @spec message(term()) :: String.t()
  def message({:evidence_required_on_review, task_name}) do
    "Review node '#{task_name}' cannot declare evidence_required"
  end

  def message({:evidence_required_requires_version_4, task_name, version}) do
    "Task '#{task_name}' declares evidence_required but pipeline version is #{inspect(version)}, not \"4\" or newer"
  end

  def message({:invalid_evidence_required, task_name, reason}) do
    "Task '#{task_name}' declares invalid evidence_required: #{reason}"
  end

  def message({:unknown_evidence_required_type, task_name, type}) do
    "Task '#{task_name}' declares unknown evidence_required type #{inspect(type)}"
  end

  defp validate_items(requirements, task_name) do
    Enum.reduce_while(requirements, :ok, fn requirement, :ok ->
      case validate_item(requirement, task_name) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_item(%{"type" => type} = requirement, task_name) when type in @types do
    with :ok <- require_string(requirement, "name", task_name),
         :ok <- validate_required(requirement, task_name),
         :ok <- validate_visibility(requirement, task_name),
         :ok <- validate_description(requirement, task_name),
         :ok <- validate_file_requirement(requirement, task_name) do
      validate_no_extra_keys(
        requirement,
        ["type", "name", "required", "visibility", "predicate", "ref_pattern", "description"],
        task_name,
        type
      )
    end
  end

  defp validate_item(%{"type" => type}, task_name) do
    {:error, {:unknown_evidence_required_type, task_name, type}}
  end

  defp validate_item(%{}, task_name) do
    {:error, {:invalid_evidence_required, task_name, "requirement requires type"}}
  end

  defp validate_item(_requirement, task_name) do
    {:error, {:invalid_evidence_required, task_name, "each requirement must be an object"}}
  end

  defp require_string(requirement, key, task_name) do
    case Map.fetch(requirement, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        :ok

      {:ok, _value} ->
        {:error, {:invalid_evidence_required, task_name, "#{key} must be a non-empty string"}}

      :error ->
        {:error, {:invalid_evidence_required, task_name, "requires #{key}"}}
    end
  end

  defp validate_required(%{"required" => value}, task_name) when not is_boolean(value) do
    {:error, {:invalid_evidence_required, task_name, "required must be a boolean"}}
  end

  defp validate_required(_requirement, _task_name), do: :ok

  defp validate_visibility(%{"visibility" => value}, task_name) when value not in @visibilities do
    {:error,
     {:invalid_evidence_required, task_name,
      "visibility must be one of #{Enum.join(@visibilities, ", ")}"}}
  end

  defp validate_visibility(_requirement, _task_name), do: :ok

  defp validate_description(%{"description" => value}, task_name)
       when not is_binary(value) or value == "" do
    {:error, {:invalid_evidence_required, task_name, "description must be a non-empty string"}}
  end

  defp validate_description(_requirement, _task_name), do: :ok

  defp validate_file_requirement(%{"type" => "file"} = requirement, task_name) do
    with :ok <- require_string(requirement, "ref_pattern", task_name) do
      case Map.get(requirement, "predicate", "exists") do
        predicate when predicate in @predicates ->
          :ok

        _predicate ->
          {:error,
           {:invalid_evidence_required, task_name,
            "file.predicate must be one of #{Enum.join(@predicates, ", ")}"}}
      end
    end
  end

  defp validate_file_requirement(%{"predicate" => _predicate}, task_name) do
    {:error, {:invalid_evidence_required, task_name, "predicate is only supported for file"}}
  end

  defp validate_file_requirement(_requirement, _task_name), do: :ok

  defp validate_no_extra_keys(requirement, allowed_keys, task_name, type) do
    extra_keys = Map.keys(requirement) -- allowed_keys

    if extra_keys == [] do
      :ok
    else
      {:error,
       {:invalid_evidence_required, task_name,
        "#{type} has unknown keys: #{Enum.join(extra_keys, ", ")}"}}
    end
  end

  defp normalize(requirements) do
    Enum.map(requirements, fn requirement ->
      requirement
      |> Map.take([
        "type",
        "name",
        "required",
        "visibility",
        "predicate",
        "ref_pattern",
        "description"
      ])
      |> Map.put_new("required", true)
      |> Map.put_new("visibility", "local")
      |> maybe_put_file_predicate()
    end)
  end

  defp maybe_put_file_predicate(%{"type" => "file"} = requirement) do
    Map.put_new(requirement, "predicate", "exists")
  end

  defp maybe_put_file_predicate(requirement), do: requirement
end
