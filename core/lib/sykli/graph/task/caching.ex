defmodule Sykli.Graph.Task.Caching do
  @moduledoc """
  Value object for task caching configuration.

  Contains properties related to cache invalidation and artifact tracking:
  - inputs: file patterns that affect cache key
  - outputs: files/artifacts produced by the task
  - task_inputs: artifacts from other tasks needed as input
  """

  @type t :: %__MODULE__{
          inputs: [String.t()],
          outputs: map() | [String.t()],
          task_inputs: [Sykli.Graph.TaskInput.t()]
        }

  defstruct inputs: [], outputs: %{}, task_inputs: []

  @doc """
  Creates a new Caching value object.
  """
  @spec new(map()) :: t()
  def new(attrs \\ %{}) do
    %__MODULE__{
      inputs: attrs[:inputs] || attrs["inputs"] || [],
      outputs: normalize_outputs(attrs[:outputs] || attrs["outputs"]),
      task_inputs: attrs[:task_inputs] || []
    }
  end

  @doc """
  Creates a Caching from a Task struct (for migration).
  """
  @spec from_task(Sykli.Graph.Task.t()) :: t()
  def from_task(task) do
    %__MODULE__{
      inputs: task.inputs || [],
      outputs: task.outputs || %{},
      task_inputs: task.task_inputs || []
    }
  end

  @doc """
  Checks if this task has any inputs defined (enabling caching).
  """
  @spec cacheable?(t()) :: boolean()
  def cacheable?(%__MODULE__{inputs: inputs}) do
    inputs != nil && inputs != []
  end

  @doc """
  Checks if this task has any artifact dependencies.
  """
  @spec has_task_inputs?(t()) :: boolean()
  def has_task_inputs?(%__MODULE__{task_inputs: task_inputs}) do
    task_inputs != nil && task_inputs != []
  end

  # Handle both v1 (list) and v2 (map) output formats
  defp normalize_outputs(nil), do: %{}

  defp normalize_outputs(outputs) when is_list(outputs) do
    outputs
    |> Enum.with_index()
    |> Map.new(fn {path, idx} -> {"output_#{idx}", path} end)
  end

  defp normalize_outputs(outputs) when is_map(outputs), do: outputs
end
