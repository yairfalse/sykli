# Sykli Elixir SDK Examples

Progressive examples from basic to advanced usage.

## Examples

| Example | Description |
|---------|-------------|
| [01-basic](./01-basic/) | Tasks, dependencies, and parallel execution |
| [02-caching](./02-caching/) | Input-based caching and conditional execution |
| [03-containers](./03-containers/) | Container execution with mounts and caches |
| [04-templates](./04-templates/) | DRY configuration with templates |
| [05-composition](./05-composition/) | Parallel groups, chains, and artifact passing |
| [06-dynamic](./06-dynamic/) | Dynamic pipelines with Elixir code |

## Running Examples

Each example is a standalone `sykli.exs` file. To run:

```bash
cd 01-basic
elixir sykli.exs --emit | sykli run -
```

Or with sykli directly:

```bash
sykli run --file examples/01-basic/sykli.exs
```

## Learning Path

Start with **01-basic** and progress through each example:

1. **01-basic**: Understand task definition and dependencies
2. **02-caching**: Learn how to skip unchanged work
3. **03-containers**: Isolate tasks in containers
4. **04-templates**: Eliminate repetition with templates
5. **05-composition**: Build complex pipelines with combinators
6. **06-dynamic**: Leverage Elixir's power for dynamic pipelines

Each example builds on concepts from previous ones.

## Key Differences from Go/Rust SDKs

The Elixir SDK uses a DSL with blocks:

```elixir
# Elixir style
task "test" do
  run "mix test"
  inputs ["**/*.ex"]
end

# vs Go style
# s.Task("test").Run("mix test").Inputs("**/*.ex")
```

Both produce the same JSON task graph.
