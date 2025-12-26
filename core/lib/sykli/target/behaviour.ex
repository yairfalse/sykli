defmodule Sykli.Target.Behaviour do
  @moduledoc """
  Behaviour defining the Target interface for pipeline execution.

  A Target abstracts WHERE pipelines execute. The same pipeline definition
  can run on different targets:

  - `Sykli.Target.Local` - Local machine (composes with Runtime for HOW)
  - `Sykli.Target.K8s` - Kubernetes Jobs + PVCs + Secrets
  - Future: API targets (GitHub Actions, GitLab CI, etc.)

  This matches the Go SDK's `Target` interface, enabling portable pipelines.

  ## Architecture

  Targets answer WHERE code runs. For local execution, they compose with
  Runtimes (see `Sykli.Runtime.Behaviour`) that answer HOW code runs:

      ┌─────────────────────────────────────────────────────────┐
      │                      TARGETS                            │
      │              (WHERE code runs)                          │
      │                                                         │
      │  ┌─────────────┐  ┌──────────────┐  ┌─────────────┐    │
      │  │   Local     │  │     K8s      │  │     API     │    │
      │  │ (machine)   │  │  (cluster)   │  │  (remote)   │    │
      │  └──────┬──────┘  └──────────────┘  └─────────────┘    │
      │         │                                               │
      │         │ composes with                                 │
      │         ▼                                               │
      │  ┌─────────────────────────────────────────────────┐   │
      │  │                   RUNTIMES                       │   │
      │  │              (HOW code runs)                     │   │
      │  │                                                  │   │
      │  │  ┌───────┐  ┌────────┐  ┌────────┐  ┌────────┐  │   │
      │  │  │ Shell │  │ Docker │  │ Podman │  │  ...   │  │   │
      │  │  └───────┘  └────────┘  └────────┘  └────────┘  │   │
      │  └─────────────────────────────────────────────────┘   │
      └─────────────────────────────────────────────────────────┘

  K8s and API targets have their own execution models and don't use Runtimes.

  ## Target Lifecycle

      setup/1     → Initialize target (verify connectivity)
      run_task/3  → Execute tasks (task, state, opts)
      teardown/1  → Cleanup resources

  ## Resource Management

  Targets manage:
  - Secrets: environment variables (local) or K8s Secrets
  - Volumes: temp directories (local) or PVCs (K8s)
  - Services: containers (local) or sidecar pods (K8s)

  ## Implementation

      defmodule MyTarget do
        @behaviour Sykli.Target.Behaviour

        @impl true
        def name, do: "my-target"

        @impl true
        def available? do
          # Check if this target can be used
          {:ok, %{version: "1.0"}}
        end

        # ... implement other callbacks
      end
  """

  # ─────────────────────────────────────────────────────────────────────────────
  # TYPES
  # ─────────────────────────────────────────────────────────────────────────────

  @typedoc "Task specification passed to run_task/2"
  @type task_spec :: Sykli.Graph.Task.t()

  @typedoc "Result from task execution"
  @type task_result :: %{
          success: boolean(),
          exit_code: integer(),
          output: String.t(),
          duration_ms: integer(),
          error: term() | nil
        }

  @typedoc "Options for volume creation"
  @type volume_opts :: %{
          optional(:size) => String.t()
        }

  @typedoc "Volume reference returned by create_volume/3"
  @type volume :: %{
          id: String.t(),
          host_path: String.t() | nil,
          reference: String.t()
        }

  @typedoc "State passed through lifecycle"
  @type state :: term()

  @typedoc "Runtime options for run_task"
  @type run_opts :: [
          workdir: String.t(),
          network: String.t() | nil,
          progress: {integer(), integer()} | nil
        ]

  # ─────────────────────────────────────────────────────────────────────────────
  # IDENTITY
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Returns the target identifier (e.g., "local", "k8s").
  """
  @callback name() :: String.t()

  @doc """
  Checks if this target is available/configured.

  - Local: Docker installed and running?
  - K8s: kubeconfig valid or in-cluster?

  Returns `{:ok, info}` with target info on success,
  `{:error, reason}` if unavailable.
  """
  @callback available?() :: {:ok, map()} | {:error, term()}

  # ─────────────────────────────────────────────────────────────────────────────
  # LIFECYCLE
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Initializes the target before pipeline execution.

  Called once before any tasks run. Use for:
  - Verifying connectivity (Docker daemon, K8s API)
  - Creating shared resources (namespaces, networks)
  - Loading configuration

  Returns `{:ok, state}` where state is passed to other callbacks.
  """
  @callback setup(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Cleans up resources after pipeline completion.

  Called after all tasks finish (success or failure). Use for:
  - Removing temporary resources
  - Cleaning up networks/namespaces
  - Releasing held resources

  Receives the state from setup/1.
  """
  @callback teardown(state()) :: :ok

  # ─────────────────────────────────────────────────────────────────────────────
  # TASK EXECUTION
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Executes a single task and returns the result.

  The target handles:
  - Container execution (docker run / K8s Job)
  - Volume mounts
  - Environment variables
  - Timeout enforcement

  ## Options

  - `:workdir` - Working directory for execution
  - `:network` - Docker network name (for service communication)
  - `:progress` - `{current, total}` for progress display

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @callback run_task(task_spec(), state(), run_opts()) :: :ok | {:error, term()}

  # ─────────────────────────────────────────────────────────────────────────────
  # SECRETS
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Retrieves a secret value by name.

  - Local: reads from environment variables
  - K8s: reads from Kubernetes Secrets

  Returns `{:ok, value}` or `{:error, :not_found}`.
  """
  @callback resolve_secret(name :: String.t(), state()) ::
              {:ok, String.t()} | {:error, :not_found}

  # ─────────────────────────────────────────────────────────────────────────────
  # VOLUMES
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Provisions storage for artifacts.

  - Local: creates a temp directory
  - K8s: creates a PVC

  Returns volume info that can be mounted into tasks.
  """
  @callback create_volume(name :: String.t(), volume_opts(), state()) ::
              {:ok, volume()} | {:error, term()}

  @doc """
  Get the path where an artifact should be stored/read.

  - Local: file path in workdir
  - K8s: PVC mount path
  """
  @callback artifact_path(
              task_name :: String.t(),
              artifact_name :: String.t(),
              workdir :: String.t(),
              state()
            ) :: String.t()

  @doc """
  Copy an artifact from source to destination.

  Used for task input resolution (artifact passing between tasks).
  """
  @callback copy_artifact(
              source_path :: String.t(),
              dest_path :: String.t(),
              workdir :: String.t(),
              state()
            ) :: :ok | {:error, term()}

  # ─────────────────────────────────────────────────────────────────────────────
  # SERVICES
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Start service containers for a task.

  Services are background containers (databases, caches) that run alongside
  the main task. They're accessible via their name as hostname.

  - Local: Docker containers on a shared network
  - K8s: Sidecar containers or separate pods

  Returns network info to pass to stop_services/2.
  """
  @callback start_services(
              task_name :: String.t(),
              services :: [Sykli.Graph.Service.t()],
              state()
            ) :: {:ok, network_info :: term()} | {:error, term()}

  @doc """
  Stop service containers after task completion.

  Receives the network_info from start_services/3.
  """
  @callback stop_services(network_info :: term(), state()) :: :ok
end
