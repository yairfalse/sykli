# SYKLI

**CI in your language. No YAML. No DSL. Just code.**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/elixir-1.16%2B-purple.svg)](https://elixir-lang.org)

A CI orchestrator that lets you define pipelines in Go, Rust, or Elixir. Your pipeline is a real program that outputs a task graph, which Sykli executes in parallel.

**This is a learning project** - exploring how to build CI tools with BEAM/OTP.

**Current Status**: Core working - parallel execution, caching, cycle detection, matrix builds.

---

## How It Works

```
sykli.go  ──run──▶  JSON task graph  ──▶  parallel execution
   SDK                  stdout              Elixir engine
```

1. Sykli detects your SDK file (`sykli.go`, `sykli.rs`, or `sykli.exs`)
2. Runs it with `--emit` to get a JSON task graph
3. Executes tasks in parallel by dependency level
4. Caches results based on input file hashes

---

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/yairfalse/sykli/main/install.sh | bash

# Create sykli.go
cat > sykli.go << 'EOF'
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()
    s.Task("test").Run("go test ./...")
    s.Task("build").Run("go build -o app").After("test")
    s.Emit()
}
EOF

# Run
sykli
```

Output:
```
── Level with 1 task(s) ──
▶ test  go test ./...
✓ test  42ms

── Level with 1 task(s) ──
▶ build  go build -o app
✓ build  1.2s

─────────────────────────────────────────
✓ 2 passed in 1.3s
```

---

## SDK Examples

### Basic Tasks

```go
s := sykli.New()
s.Task("test").Run("go test ./...")
s.Task("lint").Run("go vet ./...")
s.Task("build").Run("go build -o app").After("test", "lint")
s.Emit()
```

`test` and `lint` run in parallel. `build` waits for both.

### Caching

```go
s.Task("test").
    Run("go test ./...").
    Inputs("**/*.go", "go.mod")
```

If input files haven't changed, task is skipped:
```
⊙ test  CACHED
```

### Matrix Builds

```go
s.Task("test").
    Run("go test ./...").
    Matrix("go_version", "1.21", "1.22", "1.23")
```

Expands to `test[go_version=1.21]`, `test[go_version=1.22]`, `test[go_version=1.23]`.

### Containers (v2)

```go
s := sykli.New()
src := s.Dir(".")
cache := s.Cache("go-mod")

s.Task("test").
    Container("golang:1.21").
    Mount(src, "/src").
    MountCache(cache, "/go/pkg/mod").
    Workdir("/src").
    Run("go test ./...")
s.Emit()
```

### Retry & Timeout

```go
s.Task("integration").
    Run("./integration-tests.sh").
    Retry(3).
    Timeout(300)
```

### Conditional Execution

```go
s.Task("deploy").
    Run("./deploy.sh").
    When("branch == 'main'").
    Secret("DEPLOY_TOKEN")
```

---

## All Three SDKs

### Go

```go
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()
    s.Task("test").Run("go test ./...")
    s.Task("build").Run("go build -o app").After("test")
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
Mix.install([{:sykli, path: "sdk/elixir"}])

defmodule Pipeline do
  use Sykli

  pipeline do
    task "test" do
      run "mix test"
      inputs ["**/*.ex", "mix.exs"]
    end

    task "build" do
      run "mix compile"
      after_ ["test"]
    end
  end
end
```

---

## Features

| Feature | Status |
|---------|--------|
| Go SDK | ✅ |
| Rust SDK | ✅ |
| Elixir SDK | ✅ |
| Parallel execution | ✅ |
| Content-addressed caching | ✅ |
| Cycle detection | ✅ |
| Retry & timeout | ✅ |
| Conditional execution | ✅ |
| Matrix builds | ✅ |
| Container tasks | ✅ (SDK support) |
| GitHub status API | ✅ |
| Remote execution | Planned |

---

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌────────────┐
│  sykli.go   │────▶│  JSON Graph  │────▶│   Engine   │
│    (SDK)    │     │   (stdout)   │     │  (Elixir)  │
└─────────────┘     └──────────────┘     └────────────┘
                                               │
                    ┌──────────────────────────┼──────────────────────────┐
                    ▼                          ▼                          ▼
              ┌──────────┐              ┌──────────┐              ┌──────────┐
              │  lint    │              │   test   │              │  build   │
              │ (level 0)│              │ (level 0)│              │ (level 1)│
              └──────────┘              └──────────┘              └──────────┘
```

**Why Elixir?** The same OTP code that runs locally can distribute across a cluster. Local and remote execution are the same system at different scales.

---

## Project Structure

```
sykli/
├── core/                   # Elixir engine
│   └── lib/sykli/
│       ├── detector.ex     # Finds SDK file, runs --emit
│       ├── graph.ex        # Parses JSON, topological sort
│       ├── executor.ex     # Parallel execution
│       ├── cache.ex        # Content-addressed caching
│       └── cli.ex          # CLI interface
├── sdk/
│   ├── go/                 # Go SDK (~1000 lines)
│   ├── rust/               # Rust SDK (~1500 lines)
│   └── elixir/             # Elixir SDK
└── examples/               # Working examples
```

---

## Development

```bash
# Build escript binary
cd core && mix escript.build

# Run tests
mix test

# Run from source
mix run -e 'Sykli.run(".")'
```

---

## Naming

**Sykli** (Finnish: "cycle") - Part of a Finnish tool naming theme:
- **SYKLI** (cycle) - CI orchestrator
- **NOPEA** (fast) - GitOps controller
- **KULTA** (gold) - Progressive delivery
- **RAUTA** (iron) - Gateway API controller

---

## License

MIT

---

**Learning Elixir. Learning CI. Building tools.**
