defprotocol Sykli.Target.Protocol.Storage do
  @moduledoc """
  Protocol for storage operations.

  Defines how targets handle volumes, artifacts, and file operations
  for task execution.
  """

  @doc """
  Creates a volume for task use.

  Options may include:
    - `:size` - Storage size (e.g., "1Gi")
    - `:type` - Volume type (:cache, :directory)

  Returns volume info that can be mounted into tasks.
  """
  @spec create_volume(t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_volume(target, name, opts)

  @doc """
  Returns the path where an artifact should be stored/read.
  """
  @spec artifact_path(t(), String.t(), String.t(), String.t()) :: String.t()
  def artifact_path(target, task_name, artifact_name, workdir)

  @doc """
  Copies an artifact from source to destination.

  Used for task input resolution (artifact passing between tasks).
  """
  @spec copy_artifact(t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def copy_artifact(target, source_path, dest_path, workdir)
end

# Default implementation that returns errors
defimpl Sykli.Target.Protocol.Storage, for: Any do
  def create_volume(_target, _name, _opts), do: {:error, :not_supported}

  def artifact_path(_target, task_name, artifact_name, _workdir),
    do: "#{task_name}/#{artifact_name}"

  def copy_artifact(_target, _source, _dest, _workdir), do: {:error, :not_supported}
end
