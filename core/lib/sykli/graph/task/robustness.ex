defmodule Sykli.Graph.Task.Robustness do
  @moduledoc """
  Value object for task robustness configuration.

  Contains properties related to task reliability and security:
  - retry: number of retry attempts on failure
  - secrets: list of required secret names
  - env: environment variables for the task
  """

  @type t :: %__MODULE__{
          retry: non_neg_integer() | nil,
          secrets: [String.t()],
          env: map()
        }

  defstruct retry: nil, secrets: [], env: %{}

  @doc """
  Creates a new Robustness value object.
  """
  @spec new(map()) :: t()
  def new(attrs \\ %{}) do
    %__MODULE__{
      retry: attrs[:retry] || attrs["retry"],
      secrets: attrs[:secrets] || attrs["secrets"] || [],
      env: attrs[:env] || attrs["env"] || %{}
    }
  end

  @doc """
  Creates a Robustness from a Task struct (for migration).
  """
  @spec from_task(Sykli.Graph.Task.t()) :: t()
  def from_task(task) do
    %__MODULE__{
      retry: task.retry,
      secrets: task.secrets || [],
      env: task.env || %{}
    }
  end

  @doc """
  Checks if this task has retry enabled.
  """
  @spec retriable?(t()) :: boolean()
  def retriable?(%__MODULE__{retry: retry}) do
    retry != nil && retry > 0
  end

  @doc """
  Returns the maximum number of attempts (1 + retries).
  """
  @spec max_attempts(t()) :: pos_integer()
  def max_attempts(%__MODULE__{retry: nil}), do: 1
  def max_attempts(%__MODULE__{retry: retry}), do: retry + 1

  @doc """
  Checks if this task requires secrets.
  """
  @spec requires_secrets?(t()) :: boolean()
  def requires_secrets?(%__MODULE__{secrets: secrets}) do
    secrets != nil && secrets != []
  end

  @doc """
  Checks if this task has custom environment variables.
  """
  @spec has_env?(t()) :: boolean()
  def has_env?(%__MODULE__{env: env}) do
    env != nil && map_size(env) > 0
  end
end
