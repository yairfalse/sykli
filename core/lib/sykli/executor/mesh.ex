defmodule Sykli.Executor.Mesh do
  @moduledoc """
  Distributed executor that dispatches tasks across connected BEAM nodes.

  Uses `Sykli.Mesh` to select and dispatch to available nodes in the cluster.
  Falls back to local execution when no remote nodes are connected.

  ## Usage

      # Via CLI
      sykli run --mesh

      # Via API
      Sykli.run(".", executor: Sykli.Executor.Mesh)

  ## How It Works

  1. Queries available nodes via `Mesh.available_nodes/0`
  2. Selects best node via `Mesh.select_node/3`
  3. Dispatches task via `Mesh.dispatch_task/3` (RPC to remote node)
  4. Remote node executes via `Executor.Local.run_job/2`

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

  @behaviour Sykli.Executor.Behaviour

  alias Sykli.Mesh
  alias Sykli.Executor.Local

  require Logger

  # ---------------------------------------------------------------------------
  # BEHAVIOUR IMPLEMENTATION
  # ---------------------------------------------------------------------------

  @impl true
  def run_job(task, opts) do
    workdir = Keyword.get(opts, :workdir, ".")

    # Get available nodes (includes :local if we can execute)
    candidates = Mesh.available_nodes()

    # Select best node for this task (falls back to :local on any error)
    node =
      case Mesh.select_node(task, candidates, strategy: :any) do
        {:ok, n} ->
          n

        other ->
          Logger.warning(
            "[Mesh] Failed to select node for #{task.name} (got #{inspect(other)}), falling back to :local"
          )

          :local
      end

    # Log which node we're dispatching to
    if node != :local do
      Logger.debug("[Mesh] Dispatching #{task.name} to #{node}")
    end

    # Dispatch to selected node and handle possible dispatch errors
    case Mesh.dispatch_task(task, node, workdir: workdir) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error(
          "[Mesh] Failed to dispatch #{task.name} to #{inspect(node)}: #{inspect(reason)}"
        )

        error
    end
  end

  @impl true
  def start_services(task_name, services) do
    # Services run locally - we don't distribute service containers
    Local.start_services(task_name, services)
  end

  @impl true
  def stop_services(network_info) do
    Local.stop_services(network_info)
  end

  @impl true
  def resolve_secret(name) do
    # Secrets are resolved locally
    Local.resolve_secret(name)
  end

  @impl true
  def copy_artifact(source_path, dest_path, workdir) do
    # Artifacts are copied locally
    # TODO: For remote execution, we'd need to fetch from remote node
    Local.copy_artifact(source_path, dest_path, workdir)
  end

  @impl true
  def artifact_path(task_name, artifact_name, workdir) do
    Local.artifact_path(task_name, artifact_name, workdir)
  end

  @impl true
  def available? do
    # Mesh is available if we can execute tasks (not a coordinator-only node)
    Sykli.Daemon.can_execute?(node())
  end

  @impl true
  def name, do: "mesh"
end
