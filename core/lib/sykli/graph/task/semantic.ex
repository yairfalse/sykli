defmodule Sykli.Graph.Task.Semantic do
  @moduledoc """
  Semantic metadata for AI-native task understanding.

  This value object captures what the task means to humans and AI:
  - What code it covers (for smart task selection)
  - Its intent (for context generation)
  - Its criticality (for prioritization)

  ## Example

      %Semantic{
        covers: ["src/auth/*", "src/lib/session.ex"],
        intent: "Unit tests for authentication module",
        criticality: :high
      }
  """

  @type criticality :: :high | :medium | :low

  @type t :: %__MODULE__{
          covers: [String.t()],
          intent: String.t() | nil,
          criticality: criticality() | nil
        }

  @enforce_keys []
  defstruct covers: [],
            intent: nil,
            criticality: nil

  @doc """
  Creates a Semantic struct from a map (parsed JSON).
  """
  @spec from_map(map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}

  def from_map(map) when is_map(map) do
    %__MODULE__{
      covers: map["covers"] || [],
      intent: map["intent"],
      criticality: parse_criticality(map["criticality"])
    }
  end

  @doc """
  Converts a Semantic struct to a map for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = semantic) do
    %{
      "covers" => semantic.covers,
      "intent" => semantic.intent,
      "criticality" => criticality_to_string(semantic.criticality)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == [] end)
    |> Map.new()
  end

  @doc """
  Checks if this task covers any of the given paths.

  Used for smart task selection - when files change, we can identify
  which tasks are relevant.
  """
  @spec covers_any?(t(), [String.t()]) :: boolean()
  def covers_any?(%__MODULE__{covers: []}, _paths), do: false

  def covers_any?(%__MODULE__{covers: patterns}, paths) do
    Enum.any?(paths, fn path ->
      Enum.any?(patterns, fn pattern ->
        match_pattern?(pattern, path)
      end)
    end)
  end

  @doc """
  Returns true if the task has high criticality.
  """
  @spec critical?(t()) :: boolean()
  def critical?(%__MODULE__{criticality: :high}), do: true
  def critical?(_), do: false

  # Private helpers

  defp parse_criticality("high"), do: :high
  defp parse_criticality("medium"), do: :medium
  defp parse_criticality("low"), do: :low
  defp parse_criticality(_), do: nil

  defp criticality_to_string(:high), do: "high"
  defp criticality_to_string(:medium), do: "medium"
  defp criticality_to_string(:low), do: "low"
  defp criticality_to_string(nil), do: nil

  # Simple glob-like pattern matching
  defp match_pattern?(pattern, path) do
    regex_pattern =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("**", "{{DOUBLESTAR}}")
      |> String.replace("*", "[^/]*")
      |> String.replace("{{DOUBLESTAR}}", ".*")

    Regex.match?(~r/^#{regex_pattern}$/, path)
  end
end
