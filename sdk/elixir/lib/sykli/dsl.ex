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
    update_current_task(fn t -> %{t | depends_on: t.depends_on ++ deps} end)
  end

  @doc "Applies a template's configuration to the current task."
  def from(%Sykli.Template{} = tmpl) do
    update_current_task(fn t -> Sykli.Template.apply_to(tmpl, t) end)
  end

  @doc """
  Declares that this task needs an artifact from another task's output.

  Automatically adds a dependency on the source task.

  ## Example

      task "package" do
        input_from "build", "binary", "/app"
        run "docker build -t myapp ."
      end
  """
  def input_from(from_task, output_name, dest_path)
      when is_binary(from_task) and is_binary(output_name) and is_binary(dest_path) do
    update_current_task(fn t ->
      task_input = %{from_task: from_task, output: output_name, dest: dest_path}

      # Add dependency if not already present
      deps =
        if from_task in t.depends_on do
          t.depends_on
        else
          t.depends_on ++ [from_task]
        end

      %{t | task_inputs: t.task_inputs ++ [task_input], depends_on: deps}
    end)
  end

  @doc "Makes all tasks in the group dependencies of the current task."
  def after_group(%Sykli.TaskGroup{} = group) do
    deps = Sykli.TaskGroup.task_names(group)
    update_current_task(fn t -> %{t | depends_on: t.depends_on ++ deps} end)
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

  @doc """
  Sets a type-safe condition for when this task runs.

  This is an alternative to `when_/1` that catches errors at compile time.

  ## Examples

      alias Sykli.Condition

      task "deploy" do
        run "kubectl apply"
        when_cond Condition.branch("main") |> Condition.or_cond(Condition.tag("v*"))
      end
  """
  def when_cond(%Sykli.Condition{} = condition) do
    update_current_task(fn t -> %{t | when_cond: condition} end)
  end

  @doc "Declares a required secret."
  def secret(name) when is_binary(name) do
    update_current_task(fn t -> %{t | secrets: t.secrets ++ [name]} end)
  end

  @doc "Declares multiple required secrets."
  def secrets(names) when is_list(names) do
    update_current_task(fn t -> %{t | secrets: t.secrets ++ names} end)
  end

  @doc """
  Declares a typed secret reference with explicit source.

  ## Examples

      alias Sykli.SecretRef

      task "deploy" do
        run "./deploy.sh"
        secret_from "GITHUB_TOKEN", SecretRef.from_env("GH_TOKEN")
        secret_from "DB_PASSWORD", SecretRef.from_vault("secret/data/db#password")
      end
  """
  def secret_from(name, %Sykli.SecretRef{} = ref) when is_binary(name) do
    secret_ref = %{ref | name: name}
    update_current_task(fn t -> %{t | secret_refs: t.secret_refs ++ [secret_ref]} end)
  end

  @doc """
  Sets the target for this specific task, overriding the pipeline default.

  This enables hybrid pipelines where different tasks run on different targets.

  ## Examples

      task "test" do
        run "mix test"
        target "local"
      end

      task "deploy" do
        run "kubectl apply"
        target "k8s"
      end
  """
  def target(name) when is_binary(name) do
    update_current_task(fn t -> %{t | target_name: name} end)
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
    update_current_task(fn t ->
      Logger.debug("setting retry", task: t.name, retry: count)
      %{t | retry: count}
    end)
  end

  @doc "Sets timeout in seconds."
  def timeout(seconds) when is_integer(seconds) and seconds > 0 do
    update_current_task(fn t ->
      Logger.debug("setting timeout", task: t.name, timeout: seconds)
      %{t | timeout: seconds}
    end)
  end

  @doc """
  Sets Kubernetes-specific options for this task.

  Use the builder API from `Sykli.K8s` to create options.

  ## Examples

      alias Sykli.K8s

      task "build" do
        run "cargo build"
        k8s K8s.options()
             |> K8s.memory("4Gi")
             |> K8s.cpu("2")
             |> K8s.gpu(1)
      end
  """
  def k8s(%Sykli.K8s{} = opts) do
    update_current_task(fn t ->
      Logger.debug("setting k8s options", task: t.name)
      %{t | k8s: opts}
    end)
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

  @doc """
  Mounts the current working directory to /work and sets workdir.
  This is a convenience method that combines mount + workdir for the common case.
  """
  def mount_cwd do
    mount = %{resource: "src:.", path: "/work", type: :directory}
    update_current_task(fn t -> %{t | mounts: t.mounts ++ [mount], workdir: "/work"} end)
  end

  @doc """
  Mounts the current working directory to a custom path and sets workdir.
  """
  def mount_cwd_at(container_path) when is_binary(container_path) do
    mount = %{resource: "src:.", path: container_path, type: :directory}
    update_current_task(fn t -> %{t | mounts: t.mounts ++ [mount], workdir: container_path} end)
  end

  # ============================================================================
  # TEMPLATES
  # ============================================================================

  @doc "Creates a new template with the given name."
  def template(name) when is_binary(name) and name != "" do
    Sykli.Template.new(name)
  end

  @doc "Sets the container image for tasks using this template."
  def template_container(%Sykli.Template{} = tmpl, image) do
    Sykli.Template.container(tmpl, image)
  end

  @doc "Sets the working directory for tasks using this template."
  def template_workdir(%Sykli.Template{} = tmpl, path) do
    Sykli.Template.workdir(tmpl, path)
  end

  @doc "Sets an environment variable for tasks using this template."
  def template_env(%Sykli.Template{} = tmpl, key, value) do
    Sykli.Template.env(tmpl, key, value)
  end

  @doc "Adds a directory mount for tasks using this template."
  def template_mount(%Sykli.Template{} = tmpl, resource_name, path) do
    Sykli.Template.mount(tmpl, resource_name, path)
  end

  @doc "Adds a cache mount for tasks using this template."
  def template_mount_cache(%Sykli.Template{} = tmpl, cache_name, path) do
    Sykli.Template.mount_cache(tmpl, cache_name, path)
  end

  # ============================================================================
  # COMBINATORS
  # ============================================================================

  @doc """
  Creates a group of tasks that run in parallel.

  Returns a TaskGroup that can be used as a dependency with `after_group/1`.

  ## Example

      checks = parallel("checks", [
        task_ref("lint"),
        task_ref("test")
      ])

      task "build" do
        run "mix compile"
        after_group checks
      end
  """
  def parallel(name, tasks) when is_binary(name) and is_list(tasks) do
    # Register all tasks in the group
    current_tasks = Process.get(:sykli_tasks, [])
    Process.put(:sykli_tasks, tasks ++ current_tasks)

    # Return the group
    Sykli.TaskGroup.new(name, tasks)
  end

  @doc """
  Creates a sequential dependency chain: a -> b -> c

  Each task depends on the previous one.

  ## Example

      chain([
        task_ref("deps"),
        task_ref("compile"),
        task_ref("test")
      ])
  """
  def chain(items) when is_list(items) and length(items) > 0 do
    items
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [prev, current] ->
      add_chain_dependency(current, prev)
    end)

    # Register all items
    Enum.each(items, &register_chain_item/1)
  end

  defp add_chain_dependency(%Sykli.Task{} = task, %Sykli.Task{} = prev) do
    updated = %{task | depends_on: task.depends_on ++ [prev.name]}
    # Update in process if it's there
    update_task_in_process(task.name, fn _ -> updated end)
  end

  defp add_chain_dependency(%Sykli.Task{} = task, %Sykli.TaskGroup{} = prev) do
    deps = Sykli.TaskGroup.task_names(prev)
    updated = %{task | depends_on: task.depends_on ++ deps}
    update_task_in_process(task.name, fn _ -> updated end)
  end

  defp add_chain_dependency(%Sykli.TaskGroup{} = group, prev) do
    deps = case prev do
      %Sykli.Task{name: name} -> [name]
      %Sykli.TaskGroup{} = g -> Sykli.TaskGroup.task_names(g)
    end

    Enum.each(group.tasks, fn task ->
      updated = %{task | depends_on: task.depends_on ++ deps}
      update_task_in_process(task.name, fn _ -> updated end)
    end)
  end

  defp register_chain_item(%Sykli.Task{} = task) do
    tasks = Process.get(:sykli_tasks, [])
    unless Enum.any?(tasks, &(&1.name == task.name)) do
      Process.put(:sykli_tasks, [task | tasks])
    end
  end

  defp register_chain_item(%Sykli.TaskGroup{tasks: group_tasks}) do
    tasks = Process.get(:sykli_tasks, [])
    new_tasks = Enum.reject(group_tasks, fn t ->
      Enum.any?(tasks, &(&1.name == t.name))
    end)
    Process.put(:sykli_tasks, new_tasks ++ tasks)
  end

  defp update_task_in_process(name, update_fn) do
    tasks = Process.get(:sykli_tasks, [])
    updated = Enum.map(tasks, fn t ->
      if t.name == name, do: update_fn.(t), else: t
    end)
    Process.put(:sykli_tasks, updated)
  end

  @doc """
  Creates a task reference for use in parallel/chain combinators.

  This is a convenience to create tasks inline.

  ## Example

      parallel("checks", [
        task_ref("lint") |> run_cmd("mix credo"),
        task_ref("test") |> run_cmd("mix test")
      ])
  """
  def task_ref(name) when is_binary(name) do
    Sykli.Task.new(name)
  end

  @doc "Sets the command on a task reference (for use outside task blocks)."
  def run_cmd(%Sykli.Task{} = task, command) when is_binary(command) do
    %{task | command: command}
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
