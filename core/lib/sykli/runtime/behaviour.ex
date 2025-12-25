defmodule Sykli.Runtime.Behaviour do
  @moduledoc """
  Behaviour defining HOW code executes within a target.

  While Target abstracts WHERE pipelines run (local machine, K8s cluster),
  Runtime abstracts HOW individual commands execute:

  - `Sykli.Runtime.Shell` - Direct shell execution (sh -c)
  - `Sykli.Runtime.Docker` - Docker containers
  - `Sykli.Runtime.Podman` - Podman containers (rootless)
  - Future: Containerd, Firecracker, WASM...

  ## Design Philosophy

  Targets compose with Runtimes:

      Local Target + Shell Runtime   → native execution
      Local Target + Docker Runtime  → docker run
      Local Target + Podman Runtime  → podman run

  K8s Target doesn't use Runtime - it has its own execution model (Jobs).
  API targets (GitHub Actions, etc.) also don't use Runtime.

  ## Runtime Lifecycle

      available?/0  → Is this runtime installed/usable?
      run/4         → Execute a command with options

  ## Example Implementation

      defmodule Sykli.Runtime.Docker do
        @behaviour Sykli.Runtime.Behaviour

        @impl true
        def name, do: "docker"

        @impl true
        def available? do
          case System.find_executable("docker") do
            nil -> {:error, :not_found}
            _ -> {:ok, %{type: "docker"}}
          end
        end

        @impl true
        def run(command, image, mounts, opts) do
          # docker run --rm -v ... image sh -c "command"
        end
      end
  """

  # ─────────────────────────────────────────────────────────────────────────────
  # TYPES
  # ─────────────────────────────────────────────────────────────────────────────

  @typedoc "Mount specification for container runtimes"
  @type mount :: %{
          type: :directory | :cache,
          host_path: String.t(),
          container_path: String.t()
        }

  @typedoc "Environment variable map"
  @type env :: %{String.t() => String.t()}

  @typedoc "Runtime execution options"
  @type run_opts :: [
          workdir: String.t(),
          env: env(),
          timeout_ms: pos_integer(),
          network: String.t() | nil
        ]

  @typedoc "Execution result"
  @type result :: {:ok, exit_code :: non_neg_integer(), lines :: non_neg_integer(), output :: String.t()}
                | {:error, term()}

  # ─────────────────────────────────────────────────────────────────────────────
  # IDENTITY
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Returns the runtime identifier (e.g., "shell", "docker", "podman").
  """
  @callback name() :: String.t()

  @doc """
  Checks if this runtime is available on the system.

  Returns `{:ok, info}` with runtime info (version, features),
  or `{:error, reason}` if unavailable.
  """
  @callback available?() :: {:ok, map()} | {:error, term()}

  # ─────────────────────────────────────────────────────────────────────────────
  # EXECUTION
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Execute a command.

  ## Parameters

  - `command` - Shell command to run
  - `image` - Container image (nil for shell runtime)
  - `mounts` - List of mount specifications
  - `opts` - Execution options (workdir, env, timeout_ms, network)

  ## Returns

  - `{:ok, exit_code, line_count, output}` on completion
  - `{:error, :timeout}` if execution times out
  - `{:error, reason}` on failure
  """
  @callback run(
              command :: String.t(),
              image :: String.t() | nil,
              mounts :: [mount()],
              opts :: run_opts()
            ) :: result()

  # ─────────────────────────────────────────────────────────────────────────────
  # SERVICES (optional - only for container runtimes)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Start a service container (optional callback).

  Returns container ID or reference for later cleanup.
  """
  @callback start_service(
              name :: String.t(),
              image :: String.t(),
              network :: String.t(),
              opts :: keyword()
            ) :: {:ok, container_id :: String.t()} | {:error, term()}

  @doc """
  Stop and remove a service container.
  """
  @callback stop_service(container_id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Create a network for service communication.
  """
  @callback create_network(name :: String.t()) :: {:ok, network_id :: String.t()} | {:error, term()}

  @doc """
  Remove a network.
  """
  @callback remove_network(network_id :: String.t()) :: :ok | {:error, term()}

  @optional_callbacks start_service: 4, stop_service: 1, create_network: 1, remove_network: 1
end
