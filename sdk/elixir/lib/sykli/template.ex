defmodule Sykli.Template do
  @moduledoc """
  Reusable task configuration template.

  Templates allow you to define common settings (container, mounts, env)
  that can be inherited by multiple tasks via `from/1`.

  ## Example

      pipeline do
        src = dir(".")
        cache = cache("mix-deps")

        # Define template once
        elixir_tmpl = template("elixir")
          |> template_container("elixir:1.16")
          |> template_mount(src, "/app")
          |> template_mount_cache(cache, "/root/.mix")
          |> template_workdir("/app")

        # Use in multiple tasks
        task "test" do
          from elixir_tmpl
          run "mix test"
        end

        task "lint" do
          from elixir_tmpl
          run "mix credo --strict"
        end
      end
  """

  defstruct name: nil,
            container: nil,
            workdir: nil,
            env: %{},
            mounts: []

  @type t :: %__MODULE__{
          name: String.t(),
          container: String.t() | nil,
          workdir: String.t() | nil,
          env: %{String.t() => String.t()},
          mounts: [map()]
        }

  @doc "Creates a new template with the given name."
  def new(name) when is_binary(name) and name != "" do
    %__MODULE__{name: name}
  end

  @doc "Sets the container image for tasks using this template."
  def container(%__MODULE__{} = tmpl, image) when is_binary(image) do
    %{tmpl | container: image}
  end

  @doc "Sets the working directory for tasks using this template."
  def workdir(%__MODULE__{} = tmpl, path) when is_binary(path) do
    %{tmpl | workdir: path}
  end

  @doc "Sets an environment variable for tasks using this template."
  def env(%__MODULE__{} = tmpl, key, value) when is_binary(key) do
    %{tmpl | env: Map.put(tmpl.env, key, value)}
  end

  @doc "Adds a directory mount for tasks using this template."
  def mount(%__MODULE__{} = tmpl, resource_name, path) do
    mount_entry = %{resource: resource_name, path: path, type: :directory}
    %{tmpl | mounts: tmpl.mounts ++ [mount_entry]}
  end

  @doc "Adds a cache mount for tasks using this template."
  def mount_cache(%__MODULE__{} = tmpl, cache_name, path) do
    mount_entry = %{resource: cache_name, path: path, type: :cache}
    %{tmpl | mounts: tmpl.mounts ++ [mount_entry]}
  end

  @doc """
  Mounts the current working directory to /work and sets workdir.
  This is a convenience method that combines mount + workdir for the common case.
  """
  def mount_cwd(%__MODULE__{} = tmpl) do
    mount_entry = %{resource: "src:.", path: "/work", type: :directory}
    %{tmpl | mounts: tmpl.mounts ++ [mount_entry], workdir: "/work"}
  end

  @doc """
  Mounts the current working directory to a custom path and sets workdir.
  """
  def mount_cwd_at(%__MODULE__{} = tmpl, container_path) when is_binary(container_path) do
    mount_entry = %{resource: "src:.", path: container_path, type: :directory}
    %{tmpl | mounts: tmpl.mounts ++ [mount_entry], workdir: container_path}
  end

  @doc """
  Applies a template's configuration to a task.

  Template settings are applied first, then task-specific settings override them.
  """
  def apply_to(%__MODULE__{} = tmpl, %Sykli.Task{} = task) do
    task
    |> maybe_set_container(tmpl.container)
    |> maybe_set_workdir(tmpl.workdir)
    |> merge_env(tmpl.env)
    |> prepend_mounts(tmpl.mounts)
  end

  defp maybe_set_container(task, nil), do: task
  defp maybe_set_container(%{container: nil} = task, container), do: %{task | container: container}
  defp maybe_set_container(task, _), do: task

  defp maybe_set_workdir(task, nil), do: task
  defp maybe_set_workdir(%{workdir: nil} = task, workdir), do: %{task | workdir: workdir}
  defp maybe_set_workdir(task, _), do: task

  defp merge_env(task, template_env) do
    # Template env first, task env overrides
    merged = Map.merge(template_env, task.env)
    %{task | env: merged}
  end

  defp prepend_mounts(task, template_mounts) do
    %{task | mounts: template_mounts ++ task.mounts}
  end
end
