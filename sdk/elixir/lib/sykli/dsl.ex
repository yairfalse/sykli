defmodule Sykli.DSL do
  @moduledoc """
  DSL functions for defining tasks inside a pipeline block.

  These functions are imported when you `use Sykli`.
  """

  require Logger

  # ============================================================================
  # TASK MACRO
  # ============================================================================

  @doc """
  Defines a task in the pipeline.

      task "test" do
        run "mix test"
        inputs ["**/*.ex"]
      end
  """
  defmacro task(name, do: block) do
    quote do
      # Initialize current task in process dictionary
      Process.put(:sykli_current_task, %Sykli.Task{name: unquote(name)})

      # Execute the block (run, after_, etc. will modify current task)
      unquote(block)

      # Get the completed task and add to tasks list
      completed_task = Process.get(:sykli_current_task)
      tasks = Process.get(:sykli_tasks)
      Process.put(:sykli_tasks, [completed_task | tasks])

      Logger.debug("registered task", task: unquote(name))

      # Clean up current task
      Process.delete(:sykli_current_task)
    end
  end

  # ============================================================================
  # TASK OPTIONS
  # ============================================================================

  @doc "Sets the command to run."
  def run(command) when is_binary(command) do
    update_current_task(fn t -> %{t | command: command} end)
  end

  @doc "Sets task dependencies."
  def after_(deps) when is_list(deps) do
    update_current_task(fn t -> %{t | depends_on: deps} end)
  end

  @doc "Sets the container image."
  def container(image) when is_binary(image) do
    update_current_task(fn t -> %{t | container: image} end)
  end

  @doc "Sets the working directory inside container."
  def workdir(path) when is_binary(path) do
    update_current_task(fn t -> %{t | workdir: path} end)
  end

  @doc "Sets input file patterns for caching."
  def inputs(patterns) when is_list(patterns) do
    update_current_task(fn t -> %{t | inputs: patterns} end)
  end

  @doc "Sets output paths."
  def outputs(paths) when is_list(paths) do
    output_map =
      paths
      |> Enum.with_index()
      |> Map.new(fn {path, i} -> {"output_#{i}", path} end)

    update_current_task(fn t -> %{t | outputs: output_map} end)
  end

  @doc "Sets a named output."
  def output(name, path) do
    update_current_task(fn t -> %{t | outputs: Map.put(t.outputs, name, path)} end)
  end

  @doc "Sets an environment variable."
  def env(key, value) do
    update_current_task(fn t -> %{t | env: Map.put(t.env, key, value)} end)
  end

  @doc "Sets a condition for when this task runs."
  def when_(condition) when is_binary(condition) do
    update_current_task(fn t -> %{t | condition: condition} end)
  end

  @doc "Declares a required secret."
  def secret(name) when is_binary(name) do
    update_current_task(fn t -> %{t | secrets: t.secrets ++ [name]} end)
  end

  @doc "Declares multiple required secrets."
  def secrets(names) when is_list(names) do
    update_current_task(fn t -> %{t | secrets: t.secrets ++ names} end)
  end

  @doc "Adds a matrix dimension."
  def matrix(key, values) when is_binary(key) and is_list(values) do
    update_current_task(fn t -> %{t | matrix: Map.put(t.matrix, key, values)} end)
  end

  @doc "Adds a service container."
  def service(image, name) do
    svc = %{image: image, name: name}
    update_current_task(fn t -> %{t | services: t.services ++ [svc]} end)
  end

  @doc "Sets retry count."
  def retry(count) when is_integer(count) and count >= 0 do
    task = Process.get(:sykli_current_task)
    Logger.debug("setting retry", task: task.name, retry: count)
    update_current_task(fn t -> %{t | retry: count} end)
  end

  @doc "Sets timeout in seconds."
  def timeout(seconds) when is_integer(seconds) and seconds > 0 do
    task = Process.get(:sykli_current_task)
    Logger.debug("setting timeout", task: task.name, timeout: seconds)
    update_current_task(fn t -> %{t | timeout: seconds} end)
  end

  @doc "Mounts a directory into the container."
  def mount(resource_name, path) do
    mount = %{resource: resource_name, path: path, type: :directory}
    update_current_task(fn t -> %{t | mounts: t.mounts ++ [mount]} end)
  end

  @doc "Mounts a cache volume into the container."
  def mount_cache(cache_name, path) do
    mount = %{resource: cache_name, path: path, type: :cache}
    update_current_task(fn t -> %{t | mounts: t.mounts ++ [mount]} end)
  end

  # ============================================================================
  # RESOURCES (called inside pipeline, outside task)
  # ============================================================================

  @doc "Registers a directory resource."
  def dir(path, opts \\ []) do
    name = Keyword.get(opts, :as, "src:#{path}")
    globs = Keyword.get(opts, :globs, [])
    resource = %{type: :directory, path: path, globs: globs}

    resources = Process.get(:sykli_resources)
    Process.put(:sykli_resources, Map.put(resources, name, resource))

    Logger.debug("registered directory", path: path, name: name)
    name
  end

  @doc "Registers a cache volume."
  def cache(name) do
    resource = %{type: :cache, name: name}

    resources = Process.get(:sykli_resources)
    Process.put(:sykli_resources, Map.put(resources, name, resource))

    Logger.debug("registered cache", name: name)
    name
  end

  # ============================================================================
  # ELIXIR PRESETS
  # ============================================================================

  @elixir_inputs ["**/*.ex", "**/*.exs", "mix.exs", "mix.lock"]

  @doc "Creates a mix test task."
  defmacro mix_test(opts \\ []) do
    name = Keyword.get(opts, :name, "test")
    quote do
      task unquote(name) do
        run "mix test"
        inputs unquote(@elixir_inputs)
      end
    end
  end

  @doc "Creates a mix credo task."
  defmacro mix_credo(opts \\ []) do
    name = Keyword.get(opts, :name, "credo")
    quote do
      task unquote(name) do
        run "mix credo --strict"
        inputs unquote(@elixir_inputs)
      end
    end
  end

  @doc "Creates a mix format --check-formatted task."
  defmacro mix_format(opts \\ []) do
    name = Keyword.get(opts, :name, "format")
    quote do
      task unquote(name) do
        run "mix format --check-formatted"
        inputs unquote(@elixir_inputs)
      end
    end
  end

  @doc "Creates a mix dialyzer task."
  defmacro mix_dialyzer(opts \\ []) do
    name = Keyword.get(opts, :name, "dialyzer")
    quote do
      task unquote(name) do
        run "mix dialyzer"
        inputs unquote(@elixir_inputs)
      end
    end
  end

  @doc "Creates a mix deps.get task."
  defmacro mix_deps(opts \\ []) do
    name = Keyword.get(opts, :name, "deps")
    quote do
      task unquote(name) do
        run "mix deps.get"
        inputs ["mix.exs", "mix.lock"]
      end
    end
  end

  # ============================================================================
  # INTERNAL
  # ============================================================================

  defp update_current_task(update_fn) do
    current = Process.get(:sykli_current_task)
    Process.put(:sykli_current_task, update_fn.(current))
  end
end
