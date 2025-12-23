defmodule Sykli.Task do
  @moduledoc """
  Represents a single task in a pipeline.
  """

  defstruct name: nil,
            command: nil,
            container: nil,
            workdir: nil,
            env: %{},
            mounts: [],
            inputs: [],
            outputs: %{},
            depends_on: [],
            condition: nil,
            secrets: [],
            matrix: %{},
            services: [],
            retry: nil,
            timeout: nil,
            task_inputs: []

  @type task_input :: %{from_task: String.t(), output: String.t(), dest: String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t() | nil,
          container: String.t() | nil,
          workdir: String.t() | nil,
          env: %{String.t() => String.t()},
          mounts: [map()],
          inputs: [String.t()],
          outputs: %{String.t() => String.t()},
          depends_on: [String.t()],
          condition: String.t() | nil,
          secrets: [String.t()],
          matrix: %{String.t() => [String.t()]},
          services: [map()],
          retry: non_neg_integer() | nil,
          timeout: pos_integer() | nil,
          task_inputs: [task_input()]
        }

  @doc "Creates a new task with the given name."
  def new(name) when is_binary(name) do
    %__MODULE__{name: name}
  end
end
