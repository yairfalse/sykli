defmodule Sykli.ContractSchemaVersion do
  @moduledoc """
  Central policy for supported Sykli pipeline contract schema versions.

  The top-level `version` field is the pipeline wire-format/schema version. The
  engine must reject missing, malformed, empty, or unsupported versions instead
  of silently treating them as an older format.
  """

  @supported_versions ~w(1 2 3)
  @current_version "3"

  @type validation_error ::
          :missing_contract_schema_version
          | {:invalid_contract_schema_version_type, term()}
          | :empty_contract_schema_version
          | {:unsupported_contract_schema_version, String.t()}

  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @spec current_version() :: String.t()
  def current_version, do: @current_version

  @spec fetch(map()) :: {:ok, String.t()} | {:error, validation_error()}
  def fetch(data) when is_map(data) do
    if Map.has_key?(data, "version") do
      validate(data["version"])
    else
      {:error, :missing_contract_schema_version}
    end
  end

  @spec validate(term()) :: {:ok, String.t()} | {:error, validation_error()}
  def validate(version) when is_binary(version) do
    cond do
      String.trim(version) == "" ->
        {:error, :empty_contract_schema_version}

      version in @supported_versions ->
        {:ok, version}

      true ->
        {:error, {:unsupported_contract_schema_version, version}}
    end
  end

  def validate(version), do: {:error, {:invalid_contract_schema_version_type, version}}

  @spec error_type(validation_error()) :: atom()
  def error_type(:missing_contract_schema_version), do: :missing_contract_schema_version
  def error_type(:empty_contract_schema_version), do: :empty_contract_schema_version

  def error_type({:invalid_contract_schema_version_type, _}),
    do: :invalid_contract_schema_version_type

  def error_type({:unsupported_contract_schema_version, _}),
    do: :unsupported_contract_schema_version

  @spec message(validation_error()) :: String.t()
  def message(:missing_contract_schema_version), do: "missing contract schema version"

  def message({:invalid_contract_schema_version_type, version}) do
    "invalid contract schema version: expected string, got #{type_name(version)}"
  end

  def message(:empty_contract_schema_version), do: "empty contract schema version"

  def message({:unsupported_contract_schema_version, version}) do
    "unsupported contract schema version: #{version}; supported versions: #{supported_versions_text()}"
  end

  @spec format_error(validation_error()) :: String.t()
  def format_error(reason), do: "Error: #{message(reason)}"

  @spec to_error_map(validation_error()) :: map()
  def to_error_map(reason) do
    %{
      type: error_type(reason),
      message: message(reason)
    }
  end

  @spec supported_versions_text() :: String.t()
  def supported_versions_text, do: Enum.join(@supported_versions, ", ")

  defp type_name(nil), do: "null"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "number"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_list(value), do: "array"
  defp type_name(value) when is_map(value), do: "object"
  defp type_name(value), do: inspect(value)
end
