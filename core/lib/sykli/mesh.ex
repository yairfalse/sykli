defmodule Sykli.Mesh do
  @moduledoc """
  Distributed task execution across BEAM nodes.

  The Mesh enables running tasks on remote nodes in the cluster.
  Nodes auto-discover via libcluster (see `Sykli.Cluster`), and
  tasks can be dispatched to any connected node.

  Task execution uses `Target.Local.run_task_stateless/2` which handles
  the full lifecycle (setup → run → teardown) in a single call.

  ## Usage

      # Run on a specific node
      Mesh.dispatch_task(task, :"worker@192.168.1.50", workdir: ".")

      # Run on any available node
      Mesh.dispatch_to_any(task, workdir: ".")

      # Run on all nodes (parallel)
      Mesh.broadcast_task(task, workdir: ".")

  ## Node Selection

  The mesh can automatically select nodes based on:
  - Availability (is node connected?)
  - Capabilities (does node have Docker? GPU?)
  - Load (future: least loaded node)

      Mesh.select_node(task, candidates, strategy: :any)

  ## Local Fallback

  The special node `:local` always runs on the current machine.
  If no remote nodes are connected, operations fall back to local.
  """

  alias Sykli.Target.Local
  alias Sykli.Daemon

  @type node_ref :: :local | node()
  @type dispatch_opts :: [workdir: String.t(), timeout: integer()]

  # ---------------------------------------------------------------------------
  # DISPATCH
  # ---------------------------------------------------------------------------

  @doc """
  Dispatch a task to a specific node for execution.

  ## Options

    * `:workdir` - Working directory for execution (required)
    * `:timeout` - RPC timeout in milliseconds (default: 5 minutes)

  ## Returns

    * `:ok` - Task completed successfully
    * `{:error, {:node_not_connected, node}}` - Node not reachable
    * `{:error, {:exit_code, code}}` - Task failed with exit code
    * `{:error, :timeout}` - Task timed out
    * `{:error, reason}` - Other errors

  ## Examples

      # Run locally
      Mesh.dispatch_task(task, :local, workdir: "/my/project")

      # Run on remote node
      Mesh.dispatch_task(task, :"worker@192.168.1.50", workdir: "/my/project")
  """
  @spec dispatch_task(Sykli.Graph.Task.t(), node_ref(), dispatch_opts()) ::
          :ok | {:error, term()}
  def dispatch_task(task, node, opts \\ [])

  def dispatch_task(task, :local, opts) do
    run_locally(task, opts)
  end

  def dispatch_task(task, node, opts) when node == node() do
    run_locally(task, opts)
  end

  def dispatch_task(task, node, opts) do
    if node_available?(node) do
      run_remotely(task, node, opts)
    else
      {:error, {:node_not_connected, node}}
    end
  end

  @doc """
  Dispatch a task to any available node.

  Runs on the first available node (which is `:local` by default).
  Use `strategy: :remote` with `select_node/3` to prefer remote nodes.

  ## Options

  Same as `dispatch_task/3`.
  """
  @spec dispatch_to_any(Sykli.Graph.Task.t(), dispatch_opts()) :: :ok | {:error, term()}
  def dispatch_to_any(task, opts \\ []) do
    # select_node always succeeds (falls back to :local)
    {:ok, node} = select_node(task, available_nodes(), strategy: :any)
    dispatch_task(task, node, opts)
  end

  @doc """
  Broadcast a task to all available nodes.

  Runs the task on every connected node (including local) in parallel.
  Returns a map of node => result.

  ## Examples

      results = Mesh.broadcast_task(task, workdir: ".")
      # => %{local: :ok, :"worker@host": :ok}
  """
  @spec broadcast_task(Sykli.Graph.Task.t(), dispatch_opts()) :: %{node_ref() => term()}
  def broadcast_task(task, opts \\ []) do
    nodes = available_nodes()

    nodes
    |> Enum.map(fn node ->
      {node, Task.async(fn -> dispatch_task(task, node, opts) end)}
    end)
    |> Enum.map(fn {node, task_handle} ->
      {node, Task.await(task_handle, :infinity)}
    end)
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # NODE DISCOVERY
  # ---------------------------------------------------------------------------

  @doc """
  Returns list of available nodes that can execute tasks.

  Filters out coordinator-only nodes since they cannot execute tasks.
  """
  @spec available_nodes() :: [node_ref()]
  def available_nodes do
    # :local can always execute (unless this node is a coordinator)
    local_nodes =
      if Daemon.can_execute?(node()) do
        [:local]
      else
        []
      end

    # Filter remote nodes to only those that can execute
    remote_nodes =
      Node.list()
      |> Enum.filter(&Daemon.can_execute?/1)

    local_nodes ++ remote_nodes
  end

  @doc """
  Returns list of all connected nodes (including coordinators).

  Use this when you need to see all nodes in the mesh, not just
  those that can execute tasks.
  """
  @spec all_nodes() :: [node_ref()]
  def all_nodes do
    [:local | Node.list()]
  end

  @doc """
  Check if a node is available for task dispatch.

  A node is available if it's connected AND can execute tasks.
  Coordinator-only nodes are not available for dispatch.
  """
  @spec node_available?(node_ref()) :: boolean()
  def node_available?(:local), do: Daemon.can_execute?(node())
  def node_available?(node) when node == node(), do: Daemon.can_execute?(node())

  def node_available?(node) do
    node in Node.list() and Daemon.can_execute?(node)
  end

  @doc """
  Get information about a node.

  Returns nil if node is not connected.
  """
  @spec node_info(node_ref()) :: map() | nil
  def node_info(:local) do
    %{
      name: :local,
      role: Daemon.node_role(node()),
      capabilities: local_capabilities(),
      can_execute: Daemon.can_execute?(node()),
      can_coordinate: Daemon.can_coordinate?(node()),
      load: nil
    }
  end

  def node_info(node) when node == node() do
    node_info(:local)
  end

  def node_info(node) do
    if node in Node.list() do
      # Query remote node for its capabilities
      case :rpc.call(node, __MODULE__, :local_capabilities, [], 5000) do
        {:badrpc, _reason} ->
          nil

        capabilities ->
          %{
            name: node,
            role: Daemon.node_role(node),
            capabilities: capabilities,
            can_execute: Daemon.can_execute?(node),
            can_coordinate: Daemon.can_coordinate?(node),
            load: nil
          }
      end
    else
      nil
    end
  end

  @doc """
  Get capabilities of the local node.

  Called locally or via RPC from remote nodes.
  Delegates to `Sykli.NodeProfile.capabilities/0` for labels,
  adds docker detection for backwards compatibility.
  """
  @spec local_capabilities() :: map()
  def local_capabilities do
    # Get base capabilities from NodeProfile
    caps = Sykli.NodeProfile.capabilities()

    # Add docker detection (legacy field, also in labels now)
    Map.put(caps, :docker, has_docker?())
  end

  # ---------------------------------------------------------------------------
  # NODE SELECTION
  # ---------------------------------------------------------------------------

  @doc """
  Select a node for task execution.

  Always succeeds - falls back to `:local` when no suitable nodes found.

  ## Options

    * `:strategy` - Selection strategy:
      - `:any` - First available (default)
      - `:local` - Always local
      - `:remote` - Prefer remote nodes, fall back to local

  ## Returns

    * `{:ok, node}` - Selected node (never fails, falls back to `:local`)
  """
  @spec select_node(Sykli.Graph.Task.t(), [node_ref()], keyword()) :: {:ok, node_ref()}
  def select_node(task, candidates, opts \\ [])

  def select_node(_task, [], _opts) do
    # No candidates, fall back to local
    {:ok, :local}
  end

  def select_node(_task, candidates, opts) do
    strategy = Keyword.get(opts, :strategy, :any)

    case strategy do
      :local ->
        {:ok, :local}

      :remote ->
        # Prefer remote nodes, fall back to local
        remote = Enum.find(candidates, fn n -> n != :local and n != node() end)
        {:ok, remote || :local}

      :any ->
        # Return first available
        {:ok, List.first(candidates) || :local}

      _ ->
        {:ok, :local}
    end
  end

  # ---------------------------------------------------------------------------
  # PRIVATE - EXECUTION
  # ---------------------------------------------------------------------------

  defp run_locally(task, opts) do
    workdir = Keyword.get(opts, :workdir, ".")

    Local.run_task_stateless(task, workdir: workdir)
  end

  defp run_remotely(task, node, opts) do
    workdir = Keyword.get(opts, :workdir, ".")
    timeout = Keyword.get(opts, :timeout, 300_000)

    # RPC call to run task on remote node using Target.Local
    case :rpc.call(node, Local, :run_task_stateless, [task, [workdir: workdir]], timeout) do
      {:badrpc, :nodedown} ->
        {:error, {:node_not_connected, node}}

      {:badrpc, :timeout} ->
        {:error, :timeout}

      {:badrpc, reason} ->
        {:error, {:rpc_failed, reason}}

      result ->
        result
    end
  end

  # ---------------------------------------------------------------------------
  # PRIVATE - CAPABILITIES
  # ---------------------------------------------------------------------------

  defp has_docker? do
    case System.find_executable("docker") do
      nil -> false
      _path -> true
    end
  end
end
