defmodule Sykli.Graph.Task.Dependencies do
  @moduledoc """
  Value object for task dependency configuration.

  Contains properties related to task ordering and conditional execution:
  - depends_on: list of task names this task depends on
  - condition: conditional expression for when to run
  - matrix: matrix build configuration
  - matrix_values: specific values for expanded matrix tasks
  """

  @type t :: %__MODULE__{
          depends_on: [String.t()],
          condition: String.t() | nil,
          matrix: map() | nil,
          matrix_values: map() | nil
        }

  defstruct depends_on: [], condition: nil, matrix: nil, matrix_values: nil

  @doc """
  Creates a new Dependencies value object.
  """
  @spec new(map()) :: t()
  def new(attrs \\ %{}) do
    %__MODULE__{
      depends_on: (attrs[:depends_on] || attrs["depends_on"] || []) |> Enum.uniq(),
      condition: attrs[:condition] || attrs["condition"] || attrs[:when] || attrs["when"],
      matrix: attrs[:matrix] || attrs["matrix"],
      matrix_values: attrs[:matrix_values]
    }
  end

  @doc """
  Creates a Dependencies from a Task struct (for migration).
  """
  @spec from_task(Sykli.Graph.Task.t()) :: t()
  def from_task(task) do
    %__MODULE__{
      depends_on: task.depends_on || [],
      condition: task.condition,
      matrix: task.matrix,
      matrix_values: task.matrix_values
    }
  end

  @doc """
  Checks if this task has any dependencies.
  """
  @spec has_dependencies?(t()) :: boolean()
  def has_dependencies?(%__MODULE__{depends_on: deps}) do
    deps != nil && deps != []
  end

  @doc """
  Checks if this task has a condition.
  """
  @spec conditional?(t()) :: boolean()
  def conditional?(%__MODULE__{condition: condition}) do
    condition != nil && condition != ""
  end

  @doc """
  Checks if this task is a matrix task.
  """
  @spec matrix?(t()) :: boolean()
  def matrix?(%__MODULE__{matrix: matrix}) do
    matrix != nil && map_size(matrix) > 0
  end

  @doc """
  Checks if this task is an expanded matrix task.
  """
  @spec expanded_matrix?(t()) :: boolean()
  def expanded_matrix?(%__MODULE__{matrix_values: values}) do
    values != nil && map_size(values) > 0
  end
end
