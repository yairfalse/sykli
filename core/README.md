# Sykli Core

The Elixir-based CI orchestration engine that powers Sykli.

## Overview

This is the execution engine that:
- Detects and runs SDK files (`sykli.go`, `sykli.rs`, `sykli.ts`, `sykli.exs`)
- Parses the JSON task graph emitted by SDKs
- Executes tasks in parallel by dependency level
- Manages content-addressed caching
- Provides CLI commands (`sykli run`, `sykli graph`, `sykli delta`, etc.)

## Key Modules

| Module | Purpose |
|--------|---------|
| `Sykli.CLI` | Command-line interface entry point |
| `Sykli.Detector` | Finds SDK files and runs them with `--emit` |
| `Sykli.Graph` | JSON parsing, topological sort, cycle detection |
| `Sykli.Executor` | Parallel execution by dependency level |
| `Sykli.Cache` | Content-addressed caching (SHA256) |
| `Sykli.Error` | Structured errors with hints |
| `Sykli.Target.Local` | Docker/shell execution target |
| `Sykli.Target.K8s` | Kubernetes Jobs execution target |

## Building

```bash
# Install dependencies
mix deps.get

# Compile
mix compile

# Build the CLI binary
mix escript.build

# The binary is created at ./sykli
./sykli --help
```

## Testing

The suite is split into three tiers by runtime requirement:

```bash
# Unit tier — no container runtime needed (runs against the Fake runtime)
mix test

# Docker tier — exercises real Docker behaviour
mix test.docker

# Integration tier — cross-system tests (some require Docker)
mix test.integration

# Coverage / specific files
mix test --cover
mix test test/sykli/executor_test.exs
```

Runtime selection priority (see `Sykli.Runtime.Resolver`):

1. `opts[:runtime]` / `--runtime <name>`
2. `config :sykli, :default_runtime` (`:test` env sets this to `Sykli.Runtime.Fake`)
3. `SYKLI_RUNTIME` env var (`docker` / `podman` / `shell` / `fake`)
4. Auto-detect Docker → Podman
5. Fall back to `Sykli.Runtime.Shell`

## Development

```bash
# Format code
mix format

# Check formatting
mix format --check-formatted

# Compile with warnings as errors
mix compile --warnings-as-errors
```

## Documentation

See the main [README](../README.md) for full documentation, SDK examples, and CLI reference.

Architecture decisions are documented in [docs/adr/](../docs/adr/).
