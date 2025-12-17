# Sykli

CI pipelines defined in Elixir instead of YAML.

**No YAML. No DSL. Just code.**

## Installation

```elixir
Mix.install([{:sykli, "~> 0.1"}])
```

## Usage

Create a `sykli.exs` file in your project:

```elixir
Mix.install([{:sykli, "~> 0.1"}])

use Sykli

pipeline do
  task "test" do
    run "mix test"
    inputs ["**/*.ex", "mix.exs"]
  end

  task "credo" do
    run "mix credo --strict"
  end

  task "build" do
    run "mix compile"
    after_ ["test", "credo"]
  end
end
```

Run it:

```bash
elixir sykli.exs --emit
```

## Features

- **DSL with blocks** — feels like native Elixir
- **Dependencies** — `after_ ["task1", "task2"]`
- **Containers** — `container "elixir:1.16"`
- **Caching** — `inputs` and `outputs` for smart caching
- **Conditions** — `when_ "branch == 'main'"`
- **Secrets** — `secret "HEX_API_KEY"`
- **Matrix builds** — `matrix "otp", ["25", "26"]`
- **Services** — `service "postgres:15", "db"`
- **Retries & timeouts** — `retry 3`, `timeout 300`

## Presets

Use built-in presets for common Elixir tasks:

```elixir
pipeline do
  mix_deps()
  mix_test()
  mix_credo()
  mix_format()
  mix_dialyzer()
end
```

Customize with options:

```elixir
pipeline do
  mix_test(name: "unit-tests")
end
```

## Dynamic Pipelines

Since it's real Elixir code, you can use loops, variables, and conditionals:

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

## Links

- [GitHub](https://github.com/yairfalse/sykli)
- [Documentation](https://hexdocs.pm/sykli)
