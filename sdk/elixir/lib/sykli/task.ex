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
            when_cond: nil,         # Type-safe condition (alternative to string)
            secrets: [],
            secret_refs: [],        # v2-style typed secret references
            matrix: %{},
            services: [],
            retry: nil,
            timeout: nil,
            task_inputs: [],
            target_name: nil,       # Per-task target override
            k8s: nil,               # Kubernetes-specific options
            requires: []            # Node labels required for mesh placement

  @type secret_source :: :env | :file | :vault

  @type secret_ref :: %{
          name: String.t(),
          source: secret_source(),
          key: String.t()
        }

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
          when_cond: Sykli.Condition.t() | nil,
          secrets: [String.t()],
          secret_refs: [secret_ref()],
          matrix: %{String.t() => [String.t()]},
          services: [map()],
          retry: non_neg_integer() | nil,
          timeout: pos_integer() | nil,
          task_inputs: [task_input()],
          target_name: String.t() | nil,
          k8s: Sykli.K8s.t() | nil,
          requires: [String.t()]
        }

  @doc "Creates a new task with the given name."
  def new(name) when is_binary(name) do
    %__MODULE__{name: name}
  end
end
