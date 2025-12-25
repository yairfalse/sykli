defmodule Sykli.Target.Services do
  @moduledoc """
  Optional capability: Run service containers alongside tasks.

  Implement this if your target can run background services
  (databases, caches, message queues) that tasks can connect to.

  ## Example

      defmodule MyTarget do
        @behaviour Sykli.Target
        @behaviour Sykli.Target.Services

        @impl Sykli.Target.Services
        def start_services(task_name, services, state) do
          network = create_network(task_name)
          containers = Enum.map(services, &start_container(&1, network))
          {:ok, %{network: network, containers: containers}}
        end

        @impl Sykli.Target.Services
        def stop_services(network_info, _state) do
          stop_containers(network_info.containers)
          remove_network(network_info.network)
          :ok
        end
      end

  ## Service Definition

  Services are defined in the task spec:

      %Task{
        services: [
          %Service{name: "postgres", image: "postgres:15"},
          %Service{name: "redis", image: "redis:7"}
        ]
      }

  The service `name` becomes the hostname tasks use to connect.

  ## Without Services

  If you don't implement Services, tasks that require services will fail.
  The executor checks for this capability before attempting to start services.
  """

  @doc """
  Start service containers for a task.

  ## Parameters

  - `task_name` - Name of the task that needs services
  - `services` - List of service definitions
  - `state` - Target state

  ## Returns

  - `{:ok, network_info}` - Opaque data passed to stop_services/2
  - `{:error, reason}` on failure
  """
  @callback start_services(
              task_name :: String.t(),
              services :: [Sykli.Graph.Service.t()],
              state :: term()
            ) :: {:ok, network_info :: term()} | {:error, term()}

  @doc """
  Stop and clean up service containers.

  Called after the task completes (success or failure).
  Receives the `network_info` from start_services/3.
  """
  @callback stop_services(network_info :: term(), state :: term()) :: :ok
end

# ─────────────────────────────────────────────────────────────────────────────
# Built-in service providers
# ─────────────────────────────────────────────────────────────────────────────

defmodule Sykli.Services.Docker do
  @moduledoc """
  Docker-based service containers.

  Runs services as Docker containers on a shared network.
  Services are accessible by name as hostname.

  ## Usage

      defmodule MyTarget do
        @behaviour Sykli.Target.Services

        defdelegate start_services(task, services, state), to: Sykli.Services.Docker
        defdelegate stop_services(info, state), to: Sykli.Services.Docker
      end
  """

  def start_services(_task_name, [], _state), do: {:ok, nil}

  def start_services(task_name, services, _state) do
    network_name = "sykli-#{sanitize_name(task_name)}-#{:rand.uniform(100_000)}"

    case create_network(network_name) do
      {:ok, _} ->
        IO.puts("  #{IO.ANSI.faint()}Created network #{network_name}#{IO.ANSI.reset()}")
        container_ids = start_containers(network_name, services)

        if length(services) > 0, do: Process.sleep(1000)

        {:ok, %{network: network_name, containers: container_ids}}

      {:error, reason} ->
        {:error, {:network_create_failed, reason}}
    end
  end

  def stop_services(nil, _state), do: :ok

  def stop_services(%{network: network_name, containers: container_ids}, _state) do
    docker = docker_executable()

    Enum.each(container_ids, fn id ->
      System.cmd(docker, ["rm", "-f", id], stderr_to_stdout: true)
    end)

    if network_name do
      System.cmd(docker, ["network", "rm", network_name], stderr_to_stdout: true)
      IO.puts("  #{IO.ANSI.faint()}Removed network #{network_name}#{IO.ANSI.reset()}")
    end

    :ok
  end

  defp create_network(name) do
    docker = docker_executable()

    case System.cmd(docker, ["network", "create", name], stderr_to_stdout: true) do
      {_, 0} -> {:ok, name}
      {error, _} -> {:error, error}
    end
  end

  defp start_containers(network_name, services) do
    docker = docker_executable()

    Enum.map(services, fn %Sykli.Graph.Service{image: image, name: name} ->
      container_name = "#{network_name}-#{name}"

      {output, 0} = System.cmd(docker, [
        "run", "-d",
        "--name", container_name,
        "--network", network_name,
        "--network-alias", name,
        image
      ], stderr_to_stdout: true)

      IO.puts("  #{IO.ANSI.faint()}Started service #{name} (#{image})#{IO.ANSI.reset()}")
      String.trim(output)
    end)
  end

  defp docker_executable do
    System.find_executable("docker") || "/usr/bin/docker"
  end

  defp sanitize_name(name) do
    String.replace(name, ~r/[^a-zA-Z0-9_-]/, "_")
  end
end
