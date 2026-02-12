defmodule Sykli.Executor.Mesh do
  @moduledoc """
  Distributed target that dispatches tasks across connected BEAM nodes.

  Uses `Sykli.Mesh` to select and dispatch to available nodes in the cluster.
  Falls back to local execution when no remote nodes are connected.

  ## Usage

      # Via CLI
      sykli run --mesh

      # Via API
      Sykli.run(".", target: Sykli.Executor.Mesh)

  Note: This module implements Target.Behaviour but remains in the Executor
  namespace for backwards compatibility with the `--mesh` CLI flag.

  ## How It Works

  1. Queries available nodes via `Mesh.available_nodes/0`
  2. Selects best node via `Mesh.select_node/3`
  3. Dispatches task via `Mesh.dispatch_task/3` (RPC to remote node)
  4. Remote node executes via `Target.Local.run_task_stateless/2`

  ## Prerequisites

  Nodes must be connected via the daemon:

      # On each machine
      sykli daemon start

  Nodes auto-discover via libcluster gossip on the same network.

  ## Limitations

  * **Artifacts are local-only**: Tasks running on remote nodes cannot produce
    artifacts that are then consumed by dependent tasks, because artifact paths
    and copy operations are resolved only on the local node.

  * **Services are local-only**: Service containers are started on the local
    node and are not exposed to tasks executing on remote nodes. Remote tasks
    cannot connect to services started by this executor.

  These constraints limit which pipelines can safely use mesh execution,
  particularly those that require cross-task artifact sharing or remote
  access to service containers.
  """

  @behaviour Sykli.Target.Behaviour

  alias Sykli.Mesh
  alias Sykli.NodeSelector
  alias Sykli.Target.Local

  require Logger

  defstruct [:workdir, :local_state]

  # ---------------------------------------------------------------------------
  # IDENTITY
  # ---------------------------------------------------------------------------

  @impl true
  def name, do: "mesh"

  @impl true
  def available? do
    # Mesh is available if we can execute tasks (not a coordinator-only node)
    if Sykli.Daemon.can_execute?(node()) do
      {:ok, %{nodes: length(Mesh.available_nodes())}}
    else
      {:error, :coordinator_only}
    end
  end

  # ---------------------------------------------------------------------------
  # LIFECYCLE
  # ---------------------------------------------------------------------------

  @impl true
  def setup(opts) do
    workdir = Keyword.get(opts, :workdir, ".")

    # Setup a local target for services, secrets, artifacts
    case Local.setup(opts) do
      {:ok, local_state} ->
        IO.puts(
          "#{IO.ANSI.cyan()}Target: mesh (#{length(Mesh.available_nodes())} nodes)#{IO.ANSI.reset()}"
        )

        {:ok, %__MODULE__{workdir: workdir, local_state: local_state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def teardown(%__MODULE__{local_state: local_state}) do
    Local.teardown(local_state)
  end

  # ---------------------------------------------------------------------------
  # TASK EXECUTION
  # ---------------------------------------------------------------------------

  @impl true
  def run_task(task, state, opts) do
    workdir = Keyword.get(opts, :workdir, state.workdir)

    # Get available nodes (includes :local if we can execute)
    candidates = Mesh.available_nodes()

    # Build capabilities map for all nodes
    capabilities = build_capabilities_map(candidates)

    # Runner function for NodeSelector - dispatches to a specific node
    runner = fn node, _task, _opts ->
      if node != :local do
        Logger.debug("[Mesh] Dispatching #{task.name} to #{node}")
      end

      case Mesh.dispatch_task(task, node, workdir: workdir) do
        {:ok, output} ->
          {:ok, output}

        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.warning("[Mesh] Node #{inspect(node)} failed: #{inspect(reason)}")
          error
      end
    end

    # Use NodeSelector to filter by labels and try nodes until one works
    case NodeSelector.select_and_try(task, candidates, capabilities, opts, runner) do
      {:ok, _node} ->
        :ok

      {:ok, _node, output} ->
        {:ok, output}

      {:error, %NodeSelector.PlacementError{} = error} ->
        Logger.error(
          "[Mesh] Placement failed for #{task.name}: #{NodeSelector.PlacementError.format(error)}"
        )

        {:error, error}
    end
  end

  # Build a map of node -> capabilities for NodeSelector
  defp build_capabilities_map(nodes) do
    nodes
    |> Enum.map(fn node ->
      info = Mesh.node_info(node)
      caps = if info, do: info.capabilities, else: %{labels: []}
      {node, caps}
    end)
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # SECRETS (delegated to local)
  # ---------------------------------------------------------------------------

  @impl true
  def resolve_secret(name, %__MODULE__{local_state: local_state}) do
    Local.resolve_secret(name, local_state)
  end

  # ---------------------------------------------------------------------------
  # VOLUMES (delegated to local)
  # ---------------------------------------------------------------------------

  @impl true
  def create_volume(name, volume_opts, %__MODULE__{local_state: local_state}) do
    Local.create_volume(name, volume_opts, local_state)
  end

  @impl true
  def artifact_path(task_name, artifact_name, workdir, %__MODULE__{local_state: local_state}) do
    Local.artifact_path(task_name, artifact_name, workdir, local_state)
  end

  @impl true
  def copy_artifact(source_path, dest_path, workdir, %__MODULE__{local_state: local_state}) do
    # Artifacts are copied locally
    # TODO: For remote execution, we'd need to fetch from remote node
    Local.copy_artifact(source_path, dest_path, workdir, local_state)
  end

  # ---------------------------------------------------------------------------
  # SERVICES (delegated to local)
  # ---------------------------------------------------------------------------

  @impl true
  def start_services(task_name, services, %__MODULE__{local_state: local_state}) do
    # Services run locally - we don't distribute service containers
    Local.start_services(task_name, services, local_state)
  end

  @impl true
  def stop_services(network_info, %__MODULE__{local_state: local_state}) do
    Local.stop_services(network_info, local_state)
  end
end
