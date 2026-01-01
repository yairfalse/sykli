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

    # Select best node for this task
    {:ok, node} = Mesh.select_node(task, candidates, strategy: :any)

    # Log which node we're dispatching to
    if node != :local do
      Logger.debug("[Mesh] Dispatching #{task.name} to #{node}")
    end

    # Dispatch to selected node
    Mesh.dispatch_task(task, node, workdir: workdir)
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
