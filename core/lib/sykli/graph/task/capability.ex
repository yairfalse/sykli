defmodule Sykli.Graph.Task.Capability do
  @moduledoc """
  Capability metadata for provides/needs resolution.

  Tasks can declare capabilities they provide and capabilities they need.
  The capability resolver uses this to automatically inject dependencies
  and environment variables.

  ## Example

      %Capability{
        provides: [%{name: "binary", value: "/out/app"}],
        needs: ["database-migrated"]
      }

  ## Provides

  A provide entry has:
  - `name` - capability name (must match [a-z][a-z0-9_-]*)
  - `value` - optional value, injected as SYKLI_CAP_{NAME} env var

  ## Needs

  A list of capability names this task requires. The resolver will
  automatically add a dependency on the providing task.
  """

  @type provide :: %{name: String.t(), value: String.t() | nil}

  @type t :: %__MODULE__{
          provides: [provide()],
          needs: [String.t()]
        }

  defstruct provides: [], needs: []

  @doc """
  Creates a Capability struct from a map (parsed from JSON task fields).

  Expects a map with "provides" and/or "needs" keys.
  Returns nil if both are empty or the map is nil.
  """
  @spec from_map(map() | nil) :: t() | nil
  def from_map(nil), do: nil

  def from_map(map) when is_map(map) do
    provides =
      (map["provides"] || [])
      |> Enum.map(fn
        p when is_map(p) -> %{name: p["name"], value: p["value"]}
        p when is_binary(p) -> %{name: p, value: nil}
      end)

    needs = map["needs"] || []

    if provides == [] and needs == [] do
      nil
    else
      %__MODULE__{provides: provides, needs: needs}
    end
  end

  @doc """
  Converts a Capability struct to a map for JSON serialization.

  Returns nil if the capability is nil or has no data.
  """
  @spec to_map(t() | nil) :: map() | nil
  def to_map(nil), do: nil
  def to_map(%__MODULE__{provides: [], needs: []}), do: nil

  def to_map(%__MODULE__{} = cap) do
    %{}
    |> maybe_put("provides", if(cap.provides != [], do: Enum.map(cap.provides, &provide_to_map/1)))
    |> maybe_put("needs", if(cap.needs != [], do: cap.needs))
  end

  defp provide_to_map(%{name: name, value: nil}), do: %{"name" => name}
  defp provide_to_map(%{name: name, value: value}), do: %{"name" => name, "value" => value}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
