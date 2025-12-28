defmodule Sykli.Target.Storage do
  @moduledoc """
  Optional capability: Manage volumes and artifacts.

  Implement this if your target needs to:
  - Create storage volumes for tasks
  - Pass artifacts between tasks
  - Persist build outputs

  ## Example

      defmodule MyTarget do
        @behaviour Sykli.Target
        @behaviour Sykli.Target.Storage

        @impl Sykli.Target.Storage
        def create_volume(name, opts, state) do
          size = opts[:size] || "1Gi"
          # Create PVC, EBS volume, temp dir, etc.
          {:ok, %{id: name, reference: "pvc:" <> name}}
        end

        @impl Sykli.Target.Storage
        def artifact_path(task_name, artifact_name, _state) do
          "/artifacts/" <> task_name <> "/" <> artifact_name
        end

        @impl Sykli.Target.Storage
        def copy_artifact(source, dest, state) do
          # Copy from source to dest
          :ok
        end
      end

  ## Without Storage

  If you don't implement Storage:
  - Tasks cannot define output artifacts
  - Task inputs (from other tasks) won't work
  - Volumes/caches won't be mounted

  This is fine for simple targets that don't need artifact passing.
  """

  @typedoc "Volume reference returned by create_volume/3"
  @type volume :: %{
          id: String.t(),
          host_path: String.t() | nil,
          reference: String.t()
        }

  @doc """
  Create a storage volume.

  ## Parameters

  - `name` - Volume name
  - `opts` - Options (e.g., `%{size: "10Gi"}`)
  - `state` - Target state

  ## Returns

  - `{:ok, volume}` with volume info
  - `{:error, reason}` on failure
  """
  @callback create_volume(name :: String.t(), opts :: map(), state :: term()) ::
              {:ok, volume()} | {:error, term()}

  @doc """
  Get the path where an artifact should be stored.

  This path is used both for writing outputs and reading inputs.
  """
  @callback artifact_path(
              task_name :: String.t(),
              artifact_name :: String.t(),
              state :: term()
            ) :: String.t()

  @doc """
  Copy an artifact from one location to another.

  Used for task input resolution - copying outputs from
  one task to inputs for another.
  """
  @callback copy_artifact(
              source_path :: String.t(),
              dest_path :: String.t(),
              state :: term()
            ) :: :ok | {:error, term()}
end

# ─────────────────────────────────────────────────────────────────────────────
# Built-in storage providers
# ─────────────────────────────────────────────────────────────────────────────

defmodule Sykli.Storage.Local do
  @moduledoc """
  Local filesystem storage.

  Stores volumes and artifacts in local directories.
  Good for development and simple CI setups.

  ## Usage

      defmodule MyTarget do
        @behaviour Sykli.Target.Storage

        def create_volume(name, opts, state) do
          Sykli.Storage.Local.create_volume(name, opts, state.workdir)
        end

        def artifact_path(task, artifact, state) do
          Sykli.Storage.Local.artifact_path(task, artifact, state.workdir)
        end

        def copy_artifact(src, dst, state) do
          Sykli.Storage.Local.copy_artifact(src, dst, state.workdir)
        end
      end
  """

  def create_volume(name, _opts, workdir) do
    path = Path.join([workdir, ".sykli", "volumes", name])

    case File.mkdir_p(path) do
      :ok -> {:ok, %{id: name, host_path: path, reference: path}}
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  def artifact_path(task_name, artifact_name, workdir) do
    Path.join([workdir, ".sykli", "artifacts", task_name, artifact_name])
  end

  def copy_artifact(source_path, dest_path, workdir) do
    abs_source = Path.join(workdir, source_path) |> Path.expand()
    abs_dest = Path.join(workdir, dest_path) |> Path.expand()
    abs_workdir = Path.expand(workdir)

    cond do
      not path_within?(abs_source, abs_workdir) ->
        {:error, {:path_traversal, source_path}}

      not path_within?(abs_dest, abs_workdir) ->
        {:error, {:path_traversal, dest_path}}

      File.regular?(abs_source) ->
        copy_file(abs_source, abs_dest)

      File.dir?(abs_source) ->
        copy_directory(abs_source, abs_dest)

      true ->
        {:error, {:source_not_found, source_path}}
    end
  end

  defp copy_file(abs_source, abs_dest) do
    dest_dir = Path.dirname(abs_dest)

    with :ok <- File.mkdir_p(dest_dir),
         {:ok, _bytes} <- File.copy(abs_source, abs_dest) do
      case File.stat(abs_source) do
        {:ok, %{mode: mode}} -> File.chmod(abs_dest, mode)
        _ -> :ok
      end

      :ok
    else
      {:error, reason} -> {:error, {:copy_failed, reason}}
    end
  end

  defp copy_directory(abs_source, abs_dest) do
    with :ok <- File.mkdir_p(abs_dest),
         {:ok, _} <- File.cp_r(abs_source, abs_dest) do
      :ok
    else
      {:error, reason, _file} -> {:error, {:copy_failed, reason}}
      {:error, reason} -> {:error, {:copy_failed, reason}}
    end
  end

  # Securely check if path is within base directory (prevents path traversal)
  defp path_within?(path, base) do
    path == base or String.starts_with?(path, base <> "/")
  end
end
