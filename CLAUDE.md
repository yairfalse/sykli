# SYKLI: CI in Your Language

**A learning project for BEAM-native CI orchestration**

---

## PROJECT STATUS

**What's Implemented:**
- Go SDK (~1000 lines) - full fluent API
- Rust SDK (~1500 lines) - full fluent API
- Elixir SDK - DSL macros
- Parallel execution by dependency level
- Content-addressed caching (SHA256)
- Cycle detection (DFS)
- Matrix build expansion
- Retry with exponential backoff
- Conditional execution
- GitHub status API

**Code Stats:**
- ~3000 lines Elixir (core)
- ~2500 lines SDK code (Go + Rust + Elixir)
- 17 core modules

---

## ARCHITECTURE OVERVIEW

```
sykli.go  ──run──▶  JSON task graph  ──▶  parallel execution
   SDK                  stdout              Elixir engine
```

### Core Pipeline

```
┌─────────────────────────────────────────────────────────────────┐
│                         Elixir Core                              │
│                                                                  │
│  Sykli.Detector                                                  │
│  └── Finds sykli.go/rs/exs, runs with --emit                    │
│                                                                  │
│  Sykli.Graph                                                     │
│  ├── Parses JSON task graph                                      │
│  ├── Matrix expansion (generates combinations)                   │
│  ├── Cycle detection (3-color DFS)                              │
│  └── Topological sort (Kahn's algorithm)                        │
│                                                                  │
│  Sykli.Executor                                                  │
│  ├── Groups tasks by level                                       │
│  ├── Task.async + Task.await_many                               │
│  └── run_with_retry/4 for retries                               │
│                                                                  │
│  Sykli.Cache                                                     │
│  └── SHA256(task|command|inputs|env|container|mounts|version)   │
└─────────────────────────────────────────────────────────────────┘
```

### Key Modules

| Module | Purpose |
|--------|---------|
| `Detector` | Finds SDK file, runs `--emit` |
| `Graph` | JSON parsing, topological sort, cycle detection |
| `Executor` | Parallel execution by level |
| `Cache` | Content-addressed caching |
| `CLI` | Command-line interface |
| `TaskError` | Structured errors with hints |
| `ConditionEvaluator` | `when:` condition parsing |
| `GitHub` | Status API integration |

---

## SDK INTERFACE

### Go (current API)

```go
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()

    // Basic
    s.Task("test").Run("go test ./...")
    s.Task("build").Run("go build -o app").After("test")

    // With inputs (enables caching)
    s.Task("test").Run("go test ./...").Inputs("**/*.go")

    // Matrix
    s.Task("test").Run("go test").Matrix("version", "1.21", "1.22")

    // Container (v2)
    src := s.Dir(".")
    cache := s.Cache("go-mod")
    s.Task("test").
        Container("golang:1.21").
        Mount(src, "/src").
        MountCache(cache, "/go/pkg/mod").
        Workdir("/src").
        Run("go test ./...")

    s.Emit()
}
```

### Rust

```rust
use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("test").run("cargo test");
    p.task("build").run("cargo build --release").after(&["test"]);
    p.emit();
}
```

### Elixir

```elixir
defmodule Pipeline do
  use Sykli

  pipeline do
    task "test" do
      run "mix test"
      inputs ["**/*.ex"]
    end

    task "build" do
      run "mix compile"
      after_ ["test"]
    end
  end
end
```

---

## FILE LOCATIONS

| What | Where |
|------|-------|
| CLI entry | `core/lib/sykli/cli.ex` |
| SDK detection | `core/lib/sykli/detector.ex` |
| Graph parsing | `core/lib/sykli/graph.ex` |
| Parallel executor | `core/lib/sykli/executor.ex` |
| Cache | `core/lib/sykli/cache.ex` |
| Go SDK | `sdk/go/sykli.go` |
| Rust SDK | `sdk/rust/src/lib.rs` |
| Elixir SDK | `sdk/elixir/lib/sykli/` |

---

## KEY ALGORITHMS

### Topological Sort (Kahn's Algorithm)

```elixir
# Calculate in-degrees, process nodes with 0 in-degree
defp do_topological_sort(tasks, in_degree, sorted) do
  case find_zero_in_degree(in_degree) do
    nil -> {:ok, Enum.reverse(sorted)}
    task_name ->
      # Remove task, decrement dependents' in-degrees
      do_topological_sort(remaining, updated_degrees, [task | sorted])
  end
end
```

### Cycle Detection (3-Color DFS)

```elixir
# WHITE = unvisited, GRAY = in progress, BLACK = done
defp dfs_visit(node, graph, colors) do
  case Map.get(colors, node) do
    :gray -> {:error, :cycle}  # Back edge = cycle
    :black -> {:ok, colors}    # Already processed
    :white ->
      colors = Map.put(colors, node, :gray)
      # Visit all neighbors
      colors = Map.put(colors, node, :black)
      {:ok, colors}
  end
end
```

### Content-Addressed Cache Key

```elixir
# Deterministic hash of all task inputs
hash = :crypto.hash(:sha256,
  task_name <> "|" <>
  command <> "|" <>
  inputs_hash <> "|" <>
  env_hash <> "|" <>
  container <> "|" <>
  mounts_hash <> "|" <>
  version
)
```

---

## VERIFICATION CHECKLIST

Before every commit:

```bash
cd core

# Format
mix format

# Tests
mix test

# Build escript
mix escript.build

# Test the binary
./sykli --help
```

---

## AGENT INSTRUCTIONS

When working on this codebase:

1. **Read first** - Understand existing patterns
2. **SDK changes** - Update all three SDKs consistently
3. **JSON schema** - Core and SDKs must agree on JSON format
4. **No shadowing** - Don't alias `Sykli.Graph.Task` (shadows Elixir's Task)
5. **Run tests** - `cd core && mix test`

**This is a learning project** - exploring BEAM patterns for CI. Ask questions if unclear.
