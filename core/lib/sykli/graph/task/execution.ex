defmodule Sykli.Graph.Task.Execution do
  @moduledoc """
  Value object for task execution configuration.

  Contains the core properties needed to execute a task:
  - name: unique identifier
  - command: shell command to run
  - container: Docker image (optional)
  - workdir: working directory inside container
  - timeout: execution timeout in seconds
  """

  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          container: String.t() | nil,
          workdir: String.t() | nil,
          timeout: pos_integer() | nil
        }

  @enforce_keys [:name, :command]
  defstruct [:name, :command, :container, :workdir, :timeout]

  @doc """
  Creates a new Execution value object.
  """
  @spec new(map()) :: t()
  def new(attrs) do
    %__MODULE__{
      name: attrs[:name] || attrs["name"],
      command: attrs[:command] || attrs["command"],
      container: attrs[:container] || attrs["container"],
      workdir: attrs[:workdir] || attrs["workdir"],
      timeout: attrs[:timeout] || attrs["timeout"]
    }
  end

  @doc """
  Creates an Execution from a Task struct (for migration).
  """
  @spec from_task(Sykli.Graph.Task.t()) :: t()
  def from_task(%{name: name, command: command} = task) do
    %__MODULE__{
      name: name,
      command: command,
      container: task.container,
      workdir: task.workdir,
      timeout: task.timeout
    }
  end
end
