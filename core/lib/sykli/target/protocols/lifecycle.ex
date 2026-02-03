defprotocol Sykli.Target.Protocol.Lifecycle do
  @moduledoc """
  Protocol for target lifecycle management.

  Defines the setup and teardown operations that all targets must implement.
  This allows targets to initialize resources before pipeline execution
  and clean them up afterward.
  """

  @doc """
  Initializes the target before pipeline execution.

  Called once before any tasks run. Use for:
  - Verifying connectivity (Docker daemon, K8s API)
  - Creating shared resources (namespaces, networks)
  - Loading configuration

  Returns `{:ok, state}` where state is passed to other operations.
  """
  @spec setup(t(), keyword()) :: {:ok, term()} | {:error, term()}
  def setup(target, opts)

  @doc """
  Cleans up resources after pipeline completion.

  Called after all tasks finish (success or failure). Use for:
  - Removing temporary resources
  - Cleaning up networks/namespaces
  - Releasing held resources
  """
  @spec teardown(t()) :: :ok
  def teardown(target)
end

# Default implementation that does nothing
defimpl Sykli.Target.Protocol.Lifecycle, for: Any do
  def setup(_target, _opts), do: {:ok, %{}}
  def teardown(_target), do: :ok
end
