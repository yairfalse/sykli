defmodule Sykli.Executor.Behaviour do
  @moduledoc """
  **DEPRECATED**: Use `Sykli.Target.Behaviour` instead.

  This behaviour is kept for backwards compatibility with `Sykli.Executor.Mesh`,
  which uses it for RPC dispatch to remote nodes. New code should use
  `Sykli.Target.Behaviour` which has a proper lifecycle (setup/teardown) and
  passes state through all callbacks.

  ## Migration

  Replace:
      @behaviour Sykli.Executor.Behaviour
      def run_job(task, opts), do: ...

  With:
      @behaviour Sykli.Target.Behaviour
      def setup(opts), do: {:ok, state}
      def run_task(task, state, opts), do: ...
      def teardown(state), do: :ok

  ---

  Behaviour defining the executor interface (legacy).

  Executors handle the actual running of tasks. Different implementations:
  - `Sykli.Executor.Local` - Docker containers + shell commands
  - `Sykli.Executor.Mesh` - Distributed execution across BEAM nodes

  The orchestration layer (Sykli.Executor) handles DAG execution, parallelism,
  caching, and progress tracking. It now delegates to Target modules by default.
  """

  @type job :: Sykli.Graph.Task.t()
  @type result :: :ok | {:error, term()}
  @type run_opts :: [
          workdir: String.t(),
          network: String.t() | nil,
          progress: {integer(), integer()} | nil
        ]

  @doc """
  Run a single job/task.

  Receives the task definition and runtime options. Should:
  - Execute the command (in container or directly)
  - Stream output to console
  - Return :ok on success, {:error, reason} on failure

  Options:
  - workdir: Working directory for execution
  - network: Docker network name (for service communication)
  - progress: {current, total} for progress display
  """
  @callback run_job(job(), run_opts()) :: result()

  @doc """
  Resolve a secret by name.

  Returns the secret value if available, error otherwise.
  - Local: reads from environment variables
  - K8s: reads from Kubernetes secrets
  """
  @callback resolve_secret(name :: String.t()) :: {:ok, String.t()} | {:error, :not_found}

  @doc """
  Get the path where an artifact should be stored/read.

  - Local: file path in workdir
  - K8s: PVC mount path
  """
  @callback artifact_path(
              task_name :: String.t(),
              artifact_name :: String.t(),
              workdir :: String.t()
            ) :: String.t()

  @doc """
  Copy an artifact from source to destination.

  Used for task input resolution (artifact passing between tasks).
  Returns :ok on success, {:error, reason} on failure.
  """
  @callback copy_artifact(
              source_path :: String.t(),
              dest_path :: String.t(),
              workdir :: String.t()
            ) :: :ok | {:error, term()}

  @doc """
  Start service containers for a task.

  Returns network info and container references that will be passed
  to stop_services/1 after task completion.

  - Local: Docker network + containers
  - K8s: Sidecar pods or services
  """
  @callback start_services(
              task_name :: String.t(),
              services :: [Sykli.Graph.Service.t()]
            ) :: {:ok, network_info :: term()} | {:error, term()}

  @doc """
  Stop service containers after task completion.

  Receives the network_info returned from start_services/2.
  """
  @callback stop_services(network_info :: term()) :: :ok

  @doc """
  Check if this executor is available/configured.

  - Local: checks for Docker
  - K8s: checks for kubeconfig/in-cluster
  """
  @callback available?() :: boolean()

  @doc """
  Human-readable name for this executor.
  """
  @callback name() :: String.t()
end
