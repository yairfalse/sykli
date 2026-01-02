# Sykli Elixir SDK

CI pipelines defined in Elixir instead of YAML.

```elixir
Mix.install([{:sykli, "~> 0.2"}])

use Sykli

pipeline do
  task "test" do
    run "mix test"
    inputs ["**/*.ex", "mix.exs"]
  end

  task "build" do
    run "mix release"
    after_ ["test"]
  end
end
```

## Installation

```elixir
Mix.install([{:sykli, "~> 0.2"}])
```

Or add to your `mix.exs`:

```elixir
defp deps do
  [{:sykli, "~> 0.2"}]
end
```

## Quick Start

Create a `sykli.exs` file in your project root:

```elixir
Mix.install([{:sykli, "~> 0.2"}])

use Sykli

pipeline do
  task "lint" do
    run "mix credo --strict"
  end

  task "test" do
    run "mix test"
  end

  task "build" do
    run "mix release"
    after_ ["lint", "test"]
  end
end
```

Run it:

```bash
sykli run
# or
elixir sykli.exs --emit | sykli run -
```

## Core Concepts

### Tasks

Tasks are the basic unit of work:

```elixir
task "test" do
  run "mix test"
end
```

### Dependencies

Define execution order with `after_`:

```elixir
task "deploy" do
  run "./deploy.sh"
  after_ ["build", "test"]  # Runs after both complete
end
```

Independent tasks run in parallel automatically.

### Input-Based Caching

Skip unchanged tasks with `inputs`:

```elixir
task "test" do
  run "mix test"
  inputs ["**/*.ex", "**/*.exs", "mix.exs", "mix.lock"]
end
```

### Outputs

Declare task outputs for artifact passing:

```elixir
task "build" do
  run "mix release"
  output "release", "_build/prod/rel/myapp"
end
```

### Conditional Execution

Run tasks based on branch, tag, or event:

```elixir
# String-based conditions
task "deploy" do
  run "./deploy.sh"
  when_ "branch == 'main'"
end

# Type-safe conditions
alias Sykli.Condition

task "release" do
  run "./release.sh"
  when_cond Condition.branch("main") |> Condition.or_cond(Condition.tag("v*"))
end
```

## Templates

Templates eliminate repetition:

```elixir
pipeline do
  # Define template
  elixir = template("elixir")
    |> template_container("elixir:1.16")
    |> template_mount("src:.", "/app")
    |> template_workdir("/app")

  # Tasks inherit from template
  task "lint" do
    from elixir
    run "mix credo"
  end

  task "test" do
    from elixir
    run "mix test"
  end
end
```

## Containers

Run tasks in isolated containers:

```elixir
pipeline do
  # Register resources
  src = dir(".")
  deps_cache = cache("mix-deps")

  task "test" do
    container "elixir:1.16"
    mount src, "/app"
    mount_cache deps_cache, "/app/deps"
    workdir "/app"
    env "MIX_ENV", "test"
    run "mix test"
  end
end
```

### Convenience Methods

```elixir
# Mount current dir to /work
task "test" do
  container "elixir:1.16"
  mount_cwd()
  run "mix test"
end

# Mount to custom path
task "build" do
  container "elixir:1.16"
  mount_cwd_at("/app")
  run "mix release"
end
```

## Composition

### Parallel Groups

```elixir
pipeline do
  checks = parallel("checks", [
    task_ref("lint") |> run_cmd("mix credo"),
    task_ref("fmt") |> run_cmd("mix format --check-formatted"),
    task_ref("test") |> run_cmd("mix test")
  ])

  task "build" do
    run "mix release"
    after_group checks
  end
end
```

### Chains

```elixir
pipeline do
  deps = task_ref("deps") |> run_cmd("mix deps.get")
  compile = task_ref("compile") |> run_cmd("mix compile")
  test = task_ref("test") |> run_cmd("mix test")

  # deps -> compile -> test
  chain([deps, compile, test])
end
```

### Artifact Passing

```elixir
task "build" do
  run "mix release"
  output "release", "_build/prod/rel/myapp"
end

# Automatically depends on "build"
task "package" do
  input_from "build", "release", "/app"
  run "docker build -t myapp ."
end
```

## Dynamic Pipelines

Since it's real Elixir, use loops, variables, and conditionals:

```elixir
pipeline do
  apps = ["api", "web", "worker"]

  for app <- apps do
    task "test-#{app}" do
      run "mix test apps/#{app}"
    end
  end

  task "deploy" do
    run "./deploy.sh"
    after_ Enum.map(apps, &"test-#{&1}")
    when_ "branch == 'main'"
  end
end
```

## Matrix Builds

```elixir
pipeline do
  # Test across Elixir versions
  versions = matrix_tasks("elixir-versions", ["1.14", "1.15", "1.16"], fn version ->
    task_ref("test-#{version}")
    |> run_cmd("mix test")
    |> with_container("elixir:#{version}")
  end)

  task "deploy" do
    run "mix release"
    after_group versions
  end
end
```

## Service Containers

```elixir
task "integration" do
  container "elixir:1.16"
  mount_cwd()
  service "postgres:15", "db"
  service "redis:7", "cache"
  env "DATABASE_URL", "postgres://postgres:postgres@db:5432/test"
  env "REDIS_URL", "redis://cache:6379"
  run "mix test --only integration"
  timeout 300
end
```

## Secrets

```elixir
# Simple secret
task "deploy" do
  secret "HEX_API_KEY"
  run "mix hex.publish"
end

# Typed secrets
alias Sykli.SecretRef

task "deploy" do
  secret_from "GITHUB_TOKEN", SecretRef.from_env("GH_TOKEN")
  secret_from "DB_PASSWORD", SecretRef.from_vault("secret/db#password")
  run "./deploy.sh"
end
```

## Retry & Timeout

```elixir
task "flaky-test" do
  run "./integration-test.sh"
  retry 3      # Retry up to 3 times
  timeout 300  # 5 minute timeout
end
```

## Kubernetes Execution

```elixir
alias Sykli.K8s

task "train-model" do
  container "pytorch/pytorch:2.0"
  run "python train.py"
  k8s K8s.options()
       |> K8s.namespace("ml-jobs")
       |> K8s.memory("32Gi")
       |> K8s.gpu(1)
       |> K8s.node_selector(%{"gpu" => "nvidia-a100"})
end

# Hybrid: some tasks local, some on K8s
task "test" do
  run "mix test"
  target "local"
end

task "train" do
  run "python train.py"
  target "k8s"
end
```

## Elixir Presets

Built-in macros for common Elixir tasks:

```elixir
pipeline do
  mix_deps()      # mix deps.get
  mix_test()      # mix test
  mix_credo()     # mix credo --strict
  mix_format()    # mix format --check-formatted
  mix_dialyzer()  # mix dialyzer
end
```

Customize with options:

```elixir
mix_test(name: "unit-tests")
```

## Examples

See the [examples directory](./examples/) for complete working examples:

- `01-basic/` - Tasks, dependencies, parallel execution
- `02-caching/` - Input-based caching and conditions
- `03-containers/` - Container execution with mounts
- `04-templates/` - DRY configuration with templates
- `05-composition/` - Parallel groups, chains, artifacts
- `06-dynamic/` - Dynamic pipelines with Elixir code

## API Reference

See [REFERENCE.md](./REFERENCE.md) for the complete API documentation.

## Links

- [GitHub](https://github.com/yairfalse/sykli)
- [Documentation](https://hexdocs.pm/sykli)

## License

MIT
