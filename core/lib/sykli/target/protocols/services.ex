defprotocol Sykli.Target.Protocol.Services do
  @moduledoc """
  Protocol for service container management.

  Defines how targets start and stop service containers (databases, caches, etc.)
  that run alongside task execution.
  """

  @doc """
  Starts service containers for a task.

  Services are background containers that run alongside the main task.
  They're accessible via their name as hostname.

  Returns network info to pass to stop_services/2.
  """
  @spec start_services(t(), String.t(), [Sykli.Graph.Service.t()]) ::
          {:ok, term()} | {:error, term()}
  def start_services(target, task_name, services)

  @doc """
  Stops service containers after task completion.

  Receives the network_info from start_services/3.
  """
  @spec stop_services(t(), term()) :: :ok
  def stop_services(target, network_info)
end

# Default implementation that does nothing
defimpl Sykli.Target.Protocol.Services, for: Any do
  def start_services(_target, _task_name, []), do: {:ok, nil}
  def start_services(_target, _task_name, _services), do: {:error, :not_supported}
  def stop_services(_target, _network_info), do: :ok
end
