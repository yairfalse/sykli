defmodule Sykli.Graph.Task.AiHooks do
  @moduledoc """
  AI behavioral hooks for task execution.

  This value object defines how AI assistants should interact with the task:
  - What to do when the task fails
  - How to select this task for execution

  ## Example

      %AiHooks{
        on_fail: :analyze,
        select: :smart
      }

  ## Hook Types

  ### on_fail
  - `:analyze` - AI should analyze failure output
  - `:retry` - AI should retry with modifications
  - `:skip` - AI can skip without analysis
  - `nil` - default behavior

  ### select
  - `:smart` - Only run if covers changed files
  - `:always` - Always run regardless of changes
  - `:manual` - Only run when explicitly requested
  - `nil` - default behavior (always)
  """

  @type on_fail :: :analyze | :retry | :skip | nil
  @type select :: :smart | :always | :manual | nil

  @type t :: %__MODULE__{
          on_fail: on_fail(),
          select: select()
        }

  @enforce_keys []
  defstruct on_fail: nil,
            select: nil

  @doc """
  Creates an AiHooks struct from a map (parsed JSON).
  """
  @spec from_map(map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}

  def from_map(map) when is_map(map) do
    %__MODULE__{
      on_fail: parse_on_fail(map["on_fail"]),
      select: parse_select(map["select"])
    }
  end

  @doc """
  Converts an AiHooks struct to a map for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = hooks) do
    %{
      "on_fail" => on_fail_to_string(hooks.on_fail),
      "select" => select_to_string(hooks.select)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Returns true if failure analysis is requested.
  """
  @spec analyze_on_fail?(t()) :: boolean()
  def analyze_on_fail?(%__MODULE__{on_fail: :analyze}), do: true
  def analyze_on_fail?(_), do: false

  @doc """
  Returns true if smart selection is enabled.
  """
  @spec smart_select?(t()) :: boolean()
  def smart_select?(%__MODULE__{select: :smart}), do: true
  def smart_select?(_), do: false

  # Private helpers

  defp parse_on_fail("analyze"), do: :analyze
  defp parse_on_fail("retry"), do: :retry
  defp parse_on_fail("skip"), do: :skip
  defp parse_on_fail(_), do: nil

  defp parse_select("smart"), do: :smart
  defp parse_select("always"), do: :always
  defp parse_select("manual"), do: :manual
  defp parse_select(_), do: nil

  defp on_fail_to_string(:analyze), do: "analyze"
  defp on_fail_to_string(:retry), do: "retry"
  defp on_fail_to_string(:skip), do: "skip"
  defp on_fail_to_string(nil), do: nil

  defp select_to_string(:smart), do: "smart"
  defp select_to_string(:always), do: "always"
  defp select_to_string(:manual), do: "manual"
  defp select_to_string(nil), do: nil
end
