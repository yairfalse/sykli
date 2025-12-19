defmodule Sykli.Cluster do
  @moduledoc """
  Cluster configuration for automatic node discovery.

  Uses libcluster with configurable strategies:

  - **Gossip** (default): UDP multicast for LAN discovery
  - **DNS**: Query DNS SRV records for cloud deployment
  - **Epmd**: Connect to known node list

  ## Configuration

      # config/config.exs
      config :sykli, :cluster,
        strategy: :gossip,
        topology: [
          sykli: [
            strategy: Cluster.Strategy.Gossip,
            config: [
              port: 45892,
              multicast_addr: "230.1.1.251"
            ]
          ]
        ]

  ## Starting the Cluster

  Add to your application supervisor:

      children = [
        # ... other children
        Sykli.Cluster
      ]

  Or start manually:

      Sykli.Cluster.start_link()

  ## Manual Connection

  For testing or when auto-discovery isn't available:

      Sykli.Cluster.connect("coordinator@192.168.1.100")
  """

  use Supervisor

  require Logger

  @default_topology [
    sykli: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        multicast_addr: "230.1.1.251",
        multicast_ttl: 1,
        broadcast_only: true
      ]
    ]
  ]

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Get topology from config or use default
    topology = Keyword.get(opts, :topology) ||
               Application.get_env(:sykli, :cluster_topology) ||
               @default_topology

    children = [
      {Cluster.Supervisor, [topology, [name: Sykli.ClusterSupervisor]]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Manually connect to a node.

  ## Examples

      Sykli.Cluster.connect("coordinator@192.168.1.100")
      Sykli.Cluster.connect(:"worker@192.168.1.101")
  """
  def connect(node) when is_binary(node) do
    connect(String.to_atom(node))
  end

  def connect(node) when is_atom(node) do
    case Node.connect(node) do
      true ->
        Logger.info("[Sykli.Cluster] Connected to #{node}")
        :ok

      false ->
        Logger.warning("[Sykli.Cluster] Failed to connect to #{node}")
        {:error, :connection_failed}

      :ignored ->
        Logger.warning("[Sykli.Cluster] Node not alive, cannot connect")
        {:error, :node_not_alive}
    end
  end

  @doc """
  Disconnect from a node.
  """
  def disconnect(node) when is_binary(node) do
    disconnect(String.to_atom(node))
  end

  def disconnect(node) when is_atom(node) do
    Node.disconnect(node)
  end

  @doc """
  List all connected nodes.
  """
  def nodes do
    Node.list()
  end

  @doc """
  Check if we're connected to a coordinator.
  """
  def has_coordinator? do
    Node.list()
    |> Enum.any?(&coordinator_node?/1)
  end

  @doc """
  Get the coordinator node if connected.
  """
  def coordinator do
    Node.list()
    |> Enum.find(&coordinator_node?/1)
  end

  defp coordinator_node?(node) do
    node
    |> Atom.to_string()
    |> String.starts_with?("coordinator@")
  end
end
