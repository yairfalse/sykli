<div align="center">

# SYKLI

### CI pipelines in your language. No YAML. No DSL. Just code.

[![GitHub Release](https://img.shields.io/github/v/release/yairfalse/sykli?style=flat-square&color=blue)](https://github.com/yairfalse/sykli/releases)
[![crates.io](https://img.shields.io/crates/v/sykli?style=flat-square&color=orange)](https://crates.io/crates/sykli)
[![Hex.pm](https://img.shields.io/hexpm/v/sykli?style=flat-square&color=purple)](https://hex.pm/packages/sykli)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg?style=flat-square)](LICENSE)

**Go** · **Rust** · **TypeScript** · **Elixir** · **Python**

[Getting Started](#-quick-start) · [Installation](#-installation) · [SDK Examples](#-sdk-examples) · [CLI Reference](#-cli-reference) · [Documentation](#-documentation)

</div>

---

> **Warning**
> Sykli is **experimental software** in active development. APIs may change between releases. We're building in public and welcome feedback, but please evaluate carefully before using in production.

---

## What is Sykli?

Sykli is a CI orchestrator where your pipeline configuration is **real code** in your language of choice. No YAML, no proprietary DSL — just a program that defines tasks and their dependencies.

```go
// sykli.go — this IS your CI config
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()

    s.Task("test").Run("go test ./...").Inputs("**/*.go")
    s.Task("build").Run("go build -o app").After("test")

    s.Emit()
}
```

Run `sykli` and it executes your tasks in parallel, with caching, retries, and container support.

### Why Code Instead of YAML?

| YAML Config | Sykli |
|-------------|-------|
| String interpolation hacks | Real variables and functions |
| Copy-paste for reuse | Templates and composition |
| Runtime errors | Compile-time type checking |
| Vendor lock-in | Standard language tooling |
| Limited logic | Full programming language |

---

## Features

| Feature | Description |
|---------|-------------|
| **Multi-language SDKs** | Go, Rust, TypeScript, Elixir, Python |
| **Parallel Execution** | Tasks run concurrently by dependency level |
| **Content-addressed Caching** | Skip unchanged tasks automatically |
| **Container Support** | Docker containers with volume mounts |
| **Node Placement** | Route tasks to nodes with specific labels (GPU, etc.) |
| **Mesh Distribution** | Spread work across machines on your network |
| **Cross-platform Verify** | Re-run tasks on different OS/arch via mesh |
| **Delta Builds** | Run only tasks affected by git changes |
| **Watch Mode** | Re-run on file changes |
| **Matrix Builds** | Test across multiple configurations |
| **Gate Tasks** | Approval points that pause the pipeline |
| **Capability Dependencies** | Tasks declare what they provide and need |

---

## Installation

### Binary (Recommended)

```bash
# macOS & Linux
curl -fsSL https://raw.githubusercontent.com/yairfalse/sykli/main/install.sh | bash
```

This installs a prebuilt binary to `~/.local/bin/sykli`.

<details>
<summary><strong>Manual Download</strong></summary>

Download from [GitHub Releases](https://github.com/yairfalse/sykli/releases/latest):

| Platform | Binary |
|----------|--------|
| macOS Apple Silicon | `sykli-macos-aarch64` |
| macOS Intel | `sykli-macos-x86_64` |
| Linux x86_64 | `sykli-linux-x86_64` |
| Linux ARM64 | `sykli-linux-aarch64` |

</details>

<details>
<summary><strong>Build from Source</strong></summary>

```bash
git clone https://github.com/yairfalse/sykli.git
cd sykli/core
mix deps.get
mix escript.build
sudo mv sykli /usr/local/bin/
```

Requires Elixir 1.14+.

</details>

---

## Quick Start

### 1. Initialize

```bash
sykli init    # Auto-detects Go, Rust, or Elixir projects
```

Or create the SDK file manually — see [SDK Setup](#sdk-setup) below.

### 2. Run

```bash
sykli
```

```
── Level with 1 task(s) ──
▶ test   cargo test
✓ test   124ms

── Level with 1 task(s) ──
▶ build  cargo build --release
✓ build  1.2s

test ✓ → build ✓

✓ 2 passed in 1.4s
```

---

## SDK Setup

Sykli detects your pipeline by looking for a `sykli.*` file **in the project root**. Pick your language:

<details open>
<summary><strong>Go</strong></summary>

```bash
go get github.com/yairfalse/sykli/sdk/go@latest
```

Create `sykli.go` in your project root:

```go
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()
    s.Task("test").Run("go test ./...").Inputs("**/*.go", "go.mod")
    s.Task("build").Run("go build -o app").After("test")
    s.Emit()
}
```

</details>

<details>
<summary><strong>Rust</strong></summary>

Create `sykli.rs` in your project root, and add the dependency and binary target to your `Cargo.toml`:

```toml
# Add to your existing Cargo.toml (or create one)
[dependencies]
sykli = "0.5"

[[bin]]
name = "sykli"
path = "sykli.rs"
```

If you use a Cargo workspace, add the `[dependencies]` and `[[bin]]` sections to the **root** `Cargo.toml` (not a subdirectory).

Then create `sykli.rs`:

```rust
use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("test").run("cargo test").inputs(&["src/**/*.rs", "Cargo.toml"]);
    p.task("build").run("cargo build --release").after(&["test"]);
    p.emit();
}
```

</details>

<details>
<summary><strong>TypeScript</strong></summary>

```bash
npm install sykli
```

Create `sykli.ts` in your project root:

```typescript
import { Pipeline } from 'sykli';

const p = new Pipeline();
p.task('test').run('npm test');
p.task('build').run('npm run build').after('test');
p.emit();
```

</details>

<details>
<summary><strong>Elixir</strong></summary>

```elixir
# Add to mix.exs deps
{:sykli_sdk, "~> 0.5.1"}
```

Create `sykli.exs` in your project root:

```elixir
Sykli.pipeline do
  task "test" do
    run "mix test"
    inputs ["lib/**/*.ex", "test/**/*.exs", "mix.exs"]
  end

  task "build" do
    run "mix compile --warnings-as-errors"
    after_ ["test"]
  end
end
```

</details>

<details>
<summary><strong>Python</strong></summary>

```bash
pip install sykli
```

Create `sykli.py` in your project root:

```python
from sykli import Pipeline

p = Pipeline()
p.task("test").run("pytest")
p.task("build").run("python -m build").after("test")
p.emit()
```

</details>

> **Important:** The `sykli.*` file must be in the **project root directory** — not in a subdirectory. Sykli searches the current directory (or the path you pass) for the SDK file.

---

## SDK Examples

### Caching with Inputs

Skip tasks when input files haven't changed:

```go
s.Task("test").
    Run("go test ./...").
    Inputs("**/*.go", "go.mod", "go.sum")
```

```
⊙ test  CACHED (no input changes)
```

### Container Execution

Run tasks in Docker containers:

```go
s := sykli.New()
src := s.Dir(".")
cache := s.Cache("go-mod")

s.Task("test").
    Container("golang:1.22").
    Mount(src, "/src").
    MountCache(cache, "/go/pkg/mod").
    Workdir("/src").
    Run("go test ./...")
```

### Templates (DRY)

Define configuration once, reuse everywhere:

```go
s := sykli.New()
src := s.Dir(".")

golang := s.Template("golang").
    Container("golang:1.22").
    Mount(src, "/src").
    Workdir("/src")

s.Task("test").From(golang).Run("go test ./...")
s.Task("lint").From(golang).Run("go vet ./...")
s.Task("build").From(golang).Run("go build -o app")
```

### Node Placement

Route tasks to nodes with specific capabilities:

```go
s.Task("train").
    Requires("gpu").
    Run("python train.py")

s.Task("build-arm").
    Requires("arm64", "docker").
    Run("docker buildx build --platform=linux/arm64")
```

Nodes expose automatic labels (`darwin`, `linux`, `arm64`, `amd64`, `docker`) plus user-defined labels:

```bash
SYKLI_LABELS=gpu,team:ml sykli daemon start
```

### Capability Dependencies

Tasks declare what they provide and what they need:

```go
s.Task("build").
    Run("go build -o app").
    Provides("binary", "./app")

s.Task("deploy").
    Run("./deploy.sh").
    Needs("binary")  // auto-ordered after build
```

### Gate Tasks

Approval points that pause the pipeline:

```go
s.Gate("approve-deploy").
    Message("Deploy to production?").
    Strategy("prompt").    // interactive TTY
    Timeout("1h")

s.Task("deploy").
    Run("./deploy.sh").
    After("approve-deploy")
```

### Conditional Execution

```go
s.Task("deploy").
    Run("./deploy.sh").
    When("branch == 'main'").
    Secret("DEPLOY_TOKEN")
```

### Matrix Builds

Test across multiple configurations:

```go
s.Task("test").
    Run("go test ./...").
    Matrix("go", "1.21", "1.22", "1.23")
```

Expands to: `test[go=1.21]`, `test[go=1.22]`, `test[go=1.23]`

### Cross-platform Verification

Verify tasks pass on different OS/architecture:

```go
s.Task("build").
    Run("go build -o app").
    Verify("cross_platform")  // re-run on different OS/arch
```

```bash
sykli verify              # verify latest run on mesh
sykli verify --dry-run    # show what would be verified
```

### Parallel Groups

```go
checks := s.Parallel("checks",
    s.Task("lint").Run("go vet ./..."),
    s.Task("test").Run("go test ./..."),
    s.Task("fmt").Run("gofmt -l ."),
)

s.Task("build").After(checks)
```

### Artifact Passing

```go
build := s.Task("build").
    Run("go build -o /out/app").
    Output("binary", "/out/app")

s.Task("deploy").
    InputFrom(build, "binary", "/app/bin").
    Run("./deploy.sh /app/bin")
```

---

## CLI Reference

### Running Pipelines

```bash
sykli                          # Run all tasks
sykli --filter=test            # Run tasks matching pattern
sykli --timeout=5m             # Per-task timeout (default: 5m)
sykli --timeout 30s            # Also accepts space-separated
sykli --mesh                   # Distribute across mesh nodes
sykli --target=k8s             # Run on Kubernetes
```

### Commands

```bash
sykli init                     # Create sykli file (auto-detects language)
sykli init --rust              # Force specific language
sykli validate                 # Check pipeline without running
sykli validate --json          # Machine-readable validation output

sykli delta                    # Run only git-affected tasks
sykli delta --from=main        # Compare against branch
sykli delta --dry-run          # Show what would run

sykli watch                    # Re-run on file changes
sykli graph                    # Mermaid diagram of task graph
sykli graph --dot              # Graphviz format

sykli verify                   # Cross-platform verification via mesh
sykli verify --dry-run --json  # Preview verification plan

sykli report                   # Show last run summary
sykli report --json            # Machine-readable report
sykli history                  # List recent runs
sykli context                  # Generate .sykli/context.json

sykli cache stats              # Show cache statistics
sykli cache clean              # Clear cache

sykli daemon start             # Start mesh node
sykli daemon start --labels=gpu,docker
sykli daemon stop              # Stop mesh node
sykli daemon status            # Show mesh status
```

### Timeout Formats

```bash
sykli --timeout=0              # No timeout (infinity)
sykli --timeout=300            # Milliseconds
sykli --timeout=10s            # Seconds
sykli --timeout=5m             # Minutes (default)
sykli --timeout=2h             # Hours
sykli --timeout=1d             # Days
```

---

## How It Works

```
┌─────────────┐     ┌──────────────┐     ┌────────────┐
│  sykli.*    │────▶│  JSON Graph  │────▶│   Engine   │
│    (SDK)    │     │   (stdout)   │     │  (Elixir)  │
└─────────────┘     └──────────────┘     └────────────┘
                                               │
                    ┌──────────────────────────┼──────────────────────────┐
                    ▼                          ▼                          ▼
              ┌──────────┐              ┌──────────┐              ┌──────────┐
              │   lint   │              │   test   │              │  build   │
              │ parallel │              │ parallel │              │ depends  │
              └──────────┘              └──────────┘              └──────────┘
```

1. **Detect**: Sykli finds `sykli.go`, `sykli.rs`, `sykli.ts`, `sykli.exs`, or `sykli.py` in the current directory
2. **Emit**: Runs your SDK file with `--emit` to get a JSON task graph on stdout
3. **Execute**: Runs tasks in parallel by dependency level, with caching and retries
4. **Save**: Writes run history to `.sykli/runs/` for reporting and verification

**Why Elixir?** The BEAM VM's distribution primitives let the same engine run locally or across a cluster. Your laptop and your CI farm run identical code.

---

## Documentation

- **[ADR Index](docs/adr/)** — Architectural Decision Records
- **[SDK API Design](docs/adr/005-sdk-api.md)** — SDK philosophy
- **[Mesh Networking](docs/adr/013-mesh-swarm-design.md)** — Distributed execution
- **[Node Placement](docs/adr/017-task-placement.md)** — Label-based routing

---

## Project Status

**Current version: v0.5.1**

| Component | Status |
|-----------|--------|
| Core Engine | Stable |
| Go SDK | Stable |
| Rust SDK | Stable |
| TypeScript SDK | Stable |
| Elixir SDK | Stable |
| Python SDK | Beta |
| Local Execution | Stable |
| Container Tasks | Stable |
| Mesh Distribution | Beta |
| Cross-platform Verify | Beta |
| K8s Target | Beta |
| Gate Tasks | Beta |
| Capability Dependencies | Beta |
| Remote Cache | Planned |

---

## Contributing

Sykli is open source under the MIT license. Contributions welcome!

```bash
cd core && mix test          # Run tests (714 tests)
mix escript.build            # Build binary

test/blackbox/run.sh         # Run black-box test suite
```

---

## Naming

**Sykli** (Finnish: "cycle") — Part of a Finnish tool naming theme for infrastructure tools.

---

<div align="center">

**[Get Started](#-quick-start)** · **[GitHub](https://github.com/yairfalse/sykli)** · **[Issues](https://github.com/yairfalse/sykli/issues)**

Built in Berlin. Powered by BEAM. No YAML was harmed.

</div>
