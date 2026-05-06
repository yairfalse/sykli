defmodule Sykli.Task do
  @moduledoc """
  Represents a single task in a pipeline.
  """

  @task_types [
    :build,
    :test,
    :lint,
    :format,
    :scan,
    :package,
    :publish,
    :deploy,
    :migrate,
    :generate,
    :verify,
    :cleanup
  ]

  defstruct name: nil,
            kind: :task,
            task_type: nil,
            success_criteria: [],
            command: nil,
            primitive: nil,
            agent: nil,
            context: [],
            deterministic: false,
            container: nil,
            workdir: nil,
            env: %{},
            mounts: [],
            inputs: [],
            outputs: %{},
            depends_on: [],
            condition: nil,
            # Type-safe condition (alternative to string)
            when_cond: nil,
            secrets: [],
            # v2-style typed secret references
            secret_refs: [],
            matrix: %{},
            services: [],
            retry: nil,
            timeout: nil,
            task_inputs: [],
            # Deprecated: no longer serialized
            target_name: nil,
            # Kubernetes-specific options
            k8s: nil,
            # Node labels required for mesh placement
            requires: [],
            # AI-native: semantic metadata (covers, intent, criticality)
            semantic: nil,
            # AI-native: behavioral hooks (on_fail, select)
            ai_hooks: nil,
            # Capability-based: what this task provides
            provides: [],
            # Capability-based: what this task needs
            needs: [],
            # Gate config: %{strategy, timeout, message, env_var, file_path}
            gate: nil,
            # Cross-platform verification mode: "cross_platform", "always", "never"
            verify: nil

  @type secret_source :: :env | :file | :vault

  @type secret_ref :: %{
          name: String.t(),
          source: secret_source(),
          key: String.t()
        }

  @type task_input :: %{from_task: String.t(), output: String.t(), dest: String.t()}

  @type criticality :: :high | :medium | :low
  @type on_fail_action :: :analyze | :retry | :skip
  @type select_mode :: :smart | :always | :manual
  @type task_type ::
          :build
          | :test
          | :lint
          | :format
          | :scan
          | :package
          | :publish
          | :deploy
          | :migrate
          | :generate
          | :verify
          | :cleanup

  @type semantic :: %{
          covers: [String.t()],
          intent: String.t() | nil,
          criticality: criticality() | nil
        }

  @type ai_hooks :: %{
          on_fail: on_fail_action() | nil,
          select: select_mode() | nil
        }

  @type t :: %__MODULE__{
          name: String.t(),
          kind: :task | :review,
          task_type: task_type() | nil,
          success_criteria: [map()],
          command: String.t() | nil,
          primitive: String.t() | nil,
          agent: String.t() | nil,
          context: [String.t()],
          deterministic: boolean(),
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
          requires: [String.t()],
          semantic: semantic() | nil,
          ai_hooks: ai_hooks() | nil,
          gate: map() | nil,
          verify: String.t() | nil
        }

  @doc "Creates a new task with the given name."
  def new(name) when is_binary(name) do
    %__MODULE__{name: name}
  end

  @doc "Returns the allowed task_type values."
  def task_types, do: @task_types

  @doc "Returns true when the value is an allowed task_type."
  def valid_task_type?(type), do: type in @task_types
end
