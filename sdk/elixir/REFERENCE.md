# Sykli Elixir SDK - API Reference

Complete API documentation for the Sykli Elixir SDK.

## Table of Contents

- [Pipeline](#pipeline)
- [Task DSL](#task-dsl)
- [Template](#template)
- [Resources](#resources)
- [Composition](#composition)
- [Conditions](#conditions)
- [Secrets](#secrets)
- [Kubernetes](#kubernetes)
- [Language Presets](#language-presets)

---

## Pipeline

### use Sykli

```elixir
use Sykli
```

Imports the Sykli DSL into your module.

### pipeline

```elixir
pipeline do
  # task definitions
end
```

Defines a pipeline block containing tasks.

**Example:**
```elixir
defmodule MyPipeline do
  use Sykli

  pipeline do
    task "test" do
      run "mix test"
    end
  end
end
```

### dir

```elixir
dir(path, opts \\ [])
```

Creates a directory resource for mounting into containers.

**Options:**
- `:glob` - Filter by glob patterns

### cache

```elixir
cache(name)
```

Creates a named cache volume for persisting data between runs.

---

## Task DSL

Tasks are defined inside a `pipeline` block using the `task` macro.

### task

```elixir
task name do
  # task configuration
end
```

Creates a new task.

### run

```elixir
run(command)
```

Sets the command for this task. **Required.**

### container

```elixir
container(image)
```

Sets the container image for this task.

### mount

```elixir
mount(resource_name, path)
```

Mounts a directory into the container. Path must be absolute.

### mount_cache

```elixir
mount_cache(cache_name, path)
```

Mounts a cache volume into the container.

### mount_cwd

```elixir
mount_cwd()
```

Convenience: mounts current directory to `/work` and sets workdir.

### mount_cwd_at

```elixir
mount_cwd_at(container_path)
```

Mounts current directory to a custom path and sets workdir.

### workdir

```elixir
workdir(path)
```

Sets the working directory inside the container.

### env

```elixir
env(key, value)
```

Sets an environment variable.

### inputs

```elixir
inputs(patterns)
```

Sets input file patterns for caching. Supports glob patterns (`**/*.ex`).

### output

```elixir
output(name, path)
```

Declares a named output artifact.

### outputs

```elixir
outputs(paths)
```

Declares multiple output artifacts with auto-generated names.

### input_from

```elixir
input_from(from_task, output_name, dest_path)
```

Consumes an artifact from another task's output. Automatically adds dependency.

### after_

```elixir
after_(deps)
```

Sets dependencies - this task runs after the named tasks.

Note: Named `after_` because `after` is a reserved word in Elixir.

### after_group

```elixir
after_group(group)
```

Depends on all tasks in the given group.

### from

```elixir
from(template)
```

Applies a template's configuration. Task settings override template settings.

### when_

```elixir
when_(condition)
```

Sets a string condition for when this task should run.

Note: Named `when_` because `when` is a reserved word in Elixir.

### when_cond

```elixir
when_cond(condition)
```

Sets a type-safe condition (compile-time checked).

### secret

```elixir
secret(name)
```

Declares that this task requires a secret.

### secrets

```elixir
secrets(names)
```

Declares multiple required secrets.

### secret_from

```elixir
secret_from(name, ref)
```

Declares a typed secret reference with explicit source.

### service

```elixir
service(image, name)
```

Adds a service container (database, cache) that runs alongside this task.

### matrix

```elixir
matrix(key, values)
```

Adds a matrix dimension. Creates task variants for each value.

### retry

```elixir
retry(count)
```

Sets the number of retry attempts on failure.

### timeout

```elixir
timeout(seconds)
```

Sets the task timeout in seconds.

### target

```elixir
target(name)
```

Sets the target for this specific task, overriding pipeline default.

### k8s

```elixir
k8s(opts)
```

Adds Kubernetes-specific options. Takes a `%Sykli.K8s{}` struct.

---

## Template

Templates provide reusable task configuration.

### template

```elixir
tmpl = template("go-task")
tmpl = template_container(tmpl, "golang:1.21")
tmpl = template_workdir(tmpl, "/src")
tmpl = template_env(tmpl, "CGO_ENABLED", "0")
tmpl = template_mount(tmpl, "src", "/src")
tmpl = template_mount_cache(tmpl, "go-mod", "/go/pkg/mod")
```

**Functions:**
- `template(name)` - Create a new template
- `template_container(tmpl, image)` - Set container image
- `template_workdir(tmpl, path)` - Set working directory
- `template_env(tmpl, key, value)` - Set environment variable
- `template_mount(tmpl, resource, path)` - Mount a directory
- `template_mount_cache(tmpl, cache, path)` - Mount a cache

---

## Resources

### Directory

```elixir
%Sykli.Directory{path: String.t(), globs: [String.t()]}
```

Represents a host directory.

**Functions:**
- `dir(path)` - Create directory resource
- `dir(path, glob: ["**/*.ex"])` - With glob filter

### CacheVolume

```elixir
%Sykli.CacheVolume{name: String.t()}
```

Represents a named persistent cache.

**Functions:**
- `cache(name)` - Create cache volume

---

## Composition

### parallel

```elixir
parallel(name, tasks)
```

Creates a group of tasks that run concurrently.

### chain

```elixir
chain(items)
```

Creates a sequential dependency chain.

### matrix_tasks

```elixir
matrix_tasks(name, values, generator)
```

Creates tasks for each value using a generator function.

**Example:**
```elixir
matrix_tasks("test", ["3.11", "3.12"], fn version ->
  task_ref("test-#{version}")
  |> with_container("python:#{version}")
  |> run_cmd("pytest")
end)
```

### TaskGroup

```elixir
%Sykli.TaskGroup{name: String.t(), tasks: [Task.t()]}
```

A group of tasks created by `parallel()` or `matrix_tasks()`.

### Helper Functions

```elixir
task_ref(name)                    # Create task reference
with_container(task, image)       # Set container
with_deps(task, deps)             # Set dependencies
run_cmd(task, command)            # Set command
```

---

## Conditions

### String Conditions

```elixir
when_("branch == 'main'")
when_("tag != ''")
when_("event == 'push'")
when_("ci == true")
```

### Type-Safe Conditions

```elixir
alias Sykli.Condition

# Builders
Condition.branch(pattern)
Condition.tag(pattern)
Condition.has_tag()
Condition.event(event_type)
Condition.in_ci()
Condition.not_cond(condition)

# Combinators
Condition.or_cond(left, right)
Condition.and_cond(left, right)
```

**Examples:**
```elixir
when_cond(Condition.branch("main"))
when_cond(Condition.tag("v*"))
when_cond(Condition.or_cond(Condition.branch("main"), Condition.tag("v*")))
```

---

## Secrets

### SecretRef

```elixir
alias Sykli.SecretRef

SecretRef.from_env(env_var)      # From environment variable
SecretRef.from_file(path)        # From file
SecretRef.from_vault(path)       # From HashiCorp Vault
```

**Example:**
```elixir
secret_from("API_KEY", SecretRef.from_env("API_KEY"))
secret_from("DB_PASSWORD", SecretRef.from_vault("secret/db#password"))
```

---

## Kubernetes

### K8s Options

```elixir
alias Sykli.K8s

K8s.options()
|> K8s.memory("4Gi")
|> K8s.cpu("2")
|> K8s.gpu(1)
```

**Functions:**
- `K8s.options()` - Create empty options struct
- `K8s.memory(opts, value)` - Set memory (e.g., "4Gi", "512Mi")
- `K8s.cpu(opts, value)` - Set CPU (e.g., "2", "500m")
- `K8s.gpu(opts, count)` - Set NVIDIA GPU count
- `K8s.raw(opts, json)` - Add raw JSON for advanced options

### K8s.raw

For advanced options not covered by the minimal API (tolerations, affinity, security contexts), use raw JSON:

```elixir
K8s.options()
|> K8s.memory("32Gi")
|> K8s.gpu(1)
|> K8s.raw(~s({"nodeSelector": {"gpu": "true"}, "tolerations": [{"key": "gpu", "effect": "NoSchedule"}]}))
```

---

## Language Presets

### Elixir Input Patterns

```elixir
elixir_inputs()  # ["**/*.ex", "**/*.exs", "mix.exs", "mix.lock"]
```

### Mix Task Macros

Pre-built task macros for common Elixir operations:

```elixir
mix_test()                         # Creates 'test' task with 'mix test'
mix_test(name: "unit-tests")       # Custom task name

mix_credo()                        # Creates 'credo' task with 'mix credo --strict'
mix_credo(name: "lint")            # Custom task name

mix_format()                       # Creates 'format' task with 'mix format --check-formatted'

mix_dialyzer()                     # Creates 'dialyzer' task with 'mix dialyzer'

mix_deps()                         # Creates 'deps' task with 'mix deps.get'
```

**Example using macros:**
```elixir
defmodule MyPipeline do
  use Sykli

  pipeline do
    mix_test()
    mix_credo()
    mix_format()

    task "build" do
      run "mix compile"
      after_ ["test", "credo", "format"]
    end
  end
end
```

**Example with containers:**
```elixir
defmodule MyPipeline do
  use Sykli

  pipeline do
    src = dir(".")
    deps_cache = cache("mix-deps")
    build_cache = cache("mix-build")

    task "test" do
      container "elixir:1.16"
      mount src, "/app"
      mount_cache deps_cache, "/app/deps"
      mount_cache build_cache, "/app/_build"
      workdir "/app"
      inputs elixir_inputs()
      run "mix deps.get && mix test"
    end

    task "lint" do
      container "elixir:1.16"
      mount src, "/app"
      mount_cache deps_cache, "/app/deps"
      workdir "/app"
      run "mix deps.get && mix credo --strict"
    end

    task "build" do
      container "elixir:1.16"
      mount src, "/app"
      mount_cache deps_cache, "/app/deps"
      mount_cache build_cache, "/app/_build"
      workdir "/app"
      env "MIX_ENV", "prod"
      run "mix deps.get && mix compile"
      after_ ["test", "lint"]
    end
  end
end
```
