defmodule Sykli.Graph.Task.Infrastructure do
  @moduledoc """
  Value object for task infrastructure configuration.

  Contains properties related to execution environment:
  - mounts: volume/directory mounts
  - services: service containers (databases, caches)
  - k8s: Kubernetes-specific options
  - requires: node placement requirements
  """

  @type mount :: %{resource: String.t(), path: String.t(), type: String.t()}

  @type t :: %__MODULE__{
          mounts: [mount()],
          services: [Sykli.Graph.Service.t()],
          k8s: Sykli.Target.K8sOptions.t() | nil,
          requires: [String.t()]
        }

  defstruct mounts: [], services: [], k8s: nil, requires: []

  @doc """
  Creates a new Infrastructure value object.
  """
  @spec new(map()) :: t()
  def new(attrs \\ %{}) do
    %__MODULE__{
      mounts: attrs[:mounts] || [],
      services: attrs[:services] || [],
      k8s: attrs[:k8s],
      requires: attrs[:requires] || attrs["requires"] || []
    }
  end

  @doc """
  Creates an Infrastructure from a Task struct (for migration).
  """
  @spec from_task(Sykli.Graph.Task.t()) :: t()
  def from_task(task) do
    %__MODULE__{
      mounts: task.mounts || [],
      services: task.services || [],
      k8s: task.k8s,
      requires: task.requires || []
    }
  end

  @doc """
  Checks if this task has any mounts.
  """
  @spec has_mounts?(t()) :: boolean()
  def has_mounts?(%__MODULE__{mounts: mounts}) do
    mounts != nil && mounts != []
  end

  @doc """
  Checks if this task has any service containers.
  """
  @spec has_services?(t()) :: boolean()
  def has_services?(%__MODULE__{services: services}) do
    services != nil && services != []
  end

  @doc """
  Checks if this task has K8s-specific configuration.
  """
  @spec k8s_configured?(t()) :: boolean()
  def k8s_configured?(%__MODULE__{k8s: k8s}) do
    k8s != nil
  end

  @doc """
  Checks if this task has node placement requirements.
  """
  @spec has_requirements?(t()) :: boolean()
  def has_requirements?(%__MODULE__{requires: requires}) do
    requires != nil && requires != []
  end

  @doc """
  Returns directory mounts only.
  """
  @spec directory_mounts(t()) :: [mount()]
  def directory_mounts(%__MODULE__{mounts: mounts}) do
    Enum.filter(mounts, fn m -> m[:type] == "directory" || m["type"] == "directory" end)
  end

  @doc """
  Returns cache mounts only.
  """
  @spec cache_mounts(t()) :: [mount()]
  def cache_mounts(%__MODULE__{mounts: mounts}) do
    Enum.filter(mounts, fn m -> m[:type] == "cache" || m["type"] == "cache" end)
  end
end
