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

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/sykli/executor
```

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
