<div align="center">

# SYKLI

### CI pipelines in your language. No YAML. No DSL. Just code.

[![GitHub Release](https://img.shields.io/github/v/release/yairfalse/sykli?style=flat-square&color=blue)](https://github.com/yairfalse/sykli/releases)
[![crates.io](https://img.shields.io/crates/v/sykli?style=flat-square&color=orange)](https://crates.io/crates/sykli)
[![Hex.pm](https://img.shields.io/hexpm/v/sykli_sdk?style=flat-square&color=purple)](https://hex.pm/packages/sykli_sdk)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg?style=flat-square)](LICENSE)

**Go** · **Rust** · **TypeScript** · **Elixir**

[Getting Started](#-quick-start) · [Installation](#-installation) · [SDK Examples](#-sdk-examples) · [Documentation](#-documentation)

</div>

---

> **Warning**
> Sykli is **experimental software** in active development. APIs may change between releases. We're building in public and welcome feedback, but please evaluate carefully before using in production.

---

## What is Sykli?

Sykli is a CI orchestrator where your pipeline configuration is **real code** in your language of choice. No YAML, no proprietary DSL—just a program that defines tasks and their dependencies.

```go
// sykli.go - This IS your CI config
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
| **Multi-language SDKs** | Go, Rust, TypeScript, Elixir |
| **Parallel Execution** | Tasks run concurrently by dependency level |
| **Content-addressed Caching** | Skip unchanged tasks automatically |
| **Container Support** | Docker containers with volume mounts |
| **Node Placement** | Route tasks to nodes with specific labels (GPU, etc.) |
| **Mesh Distribution** | Spread work across machines on your network |
| **Delta Builds** | Run only tasks affected by git changes |
| **Watch Mode** | Re-run on file changes |
| **Matrix Builds** | Test across multiple configurations |

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

### SDK Installation

<table>
<tr>
<th>Go</th>
<th>Rust</th>
</tr>
<tr>
<td>

```bash
go get github.com/yairfalse/sykli/sdk/go@v0.3.0
```

</td>
<td>

```bash
cargo add sykli@0.3.0
```

</td>
</tr>
<tr>
<th>TypeScript</th>
<th>Elixir</th>
</tr>
<tr>
<td>

```bash
npm install sykli
# or
bun add sykli
```

</td>
<td>

```elixir
# mix.exs
{:sykli_sdk, "~> 0.3.0"}
```

</td>
</tr>
</table>

---

## Quick Start

### 1. Initialize

```bash
sykli init    # Auto-detects your project type
```

Or create manually:

<details>
<summary><strong>Go</strong></summary>

```go
// sykli.go
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()
    s.Task("test").Run("go test ./...")
    s.Task("build").Run("go build -o app").After("test")
    s.Emit()
}
```

</details>

<details>
<summary><strong>Rust</strong></summary>

```rust
// sykli.rs
use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("test").run("cargo test");
    p.task("build").run("cargo build --release").after(&["test"]);
    p.emit();
}
```

</details>

<details>
<summary><strong>TypeScript</strong></summary>

```typescript
// sykli.ts
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
# sykli.exs
Mix.install([{:sykli_sdk, "~> 0.3.0"}])

import Sykli

pipeline do
  task "test", run: "mix test"
  task "build", run: "mix compile", after: ["test"]
end
|> Sykli.emit()
```

</details>

### 2. Run

```bash
sykli
```

```
▶ test   go test ./...
✓ test   124ms

▶ build  go build -o app
✓ build  1.2s

test ✓ → build ✓

✓ All tasks completed in 1.4s
```

---

## SDK Examples

### Basic Pipeline

<table>
<tr><th>Go</th><th>Rust</th></tr>
<tr>
<td>

```go
s := sykli.New()

s.Task("lint").Run("go vet ./...")
s.Task("test").Run("go test ./...")
s.Task("build").
    Run("go build -o app").
    After("lint", "test")

s.Emit()
```

</td>
<td>

```rust
let mut p = Pipeline::new();

p.task("lint").run("cargo clippy");
p.task("test").run("cargo test");
p.task("build")
    .run("cargo build --release")
    .after(&["lint", "test"]);

p.emit();
```

</td>
</tr>
<tr><th>TypeScript</th><th>Elixir</th></tr>
<tr>
<td>

```typescript
const p = new Pipeline();

p.task('lint').run('eslint .');
p.task('test').run('npm test');
p.task('build')
    .run('npm run build')
    .after('lint', 'test');

p.emit();
```

</td>
<td>

```elixir
import Sykli

pipeline do
  task "lint", run: "mix credo"
  task "test", run: "mix test"
  task "build",
    run: "mix compile",
    after: ["lint", "test"]
end
|> Sykli.emit()
```

</td>
</tr>
</table>

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

// Define template
golang := s.Template("golang").
    Container("golang:1.22").
    Mount(src, "/src").
    Workdir("/src")

// Reuse
s.Task("test").From(golang).Run("go test ./...")
s.Task("lint").From(golang).Run("go vet ./...")
s.Task("build").From(golang).Run("go build -o app")
```

### Node Placement (v0.3.0)

Route tasks to nodes with specific capabilities:

```go
// Run on nodes with GPU label
s.Task("train").
    Requires("gpu").
    Run("python train.py")

// Run on nodes with both labels
s.Task("build-arm").
    Requires("arm64", "docker").
    Run("docker buildx build --platform=linux/arm64")
```

Nodes expose automatic labels (`darwin`, `linux`, `arm64`, `amd64`, `docker`) plus user-defined labels:

```bash
# Set labels on a node
SYKLI_LABELS=gpu,team:ml sykli daemon start
```

### Conditional Execution

```go
s.Task("deploy").
    Run("./deploy.sh").
    When("branch == 'main'").
    Secret("DEPLOY_TOKEN")
```

Or with type-safe conditions:

```go
s.Task("deploy").
    Run("./deploy.sh").
    WhenCond(sykli.Branch("main").Or(sykli.HasTag()))
```

### Matrix Builds

Test across multiple configurations:

```go
s.Task("test").
    Run("go test ./...").
    Matrix("go", "1.21", "1.22", "1.23")
```

Expands to: `test[go=1.21]`, `test[go=1.22]`, `test[go=1.23]`

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

```bash
sykli                      # Run all tasks
sykli --filter=test        # Run tasks matching pattern
sykli --mesh               # Distribute across network

sykli init                 # Create sykli file for your project
sykli validate             # Check pipeline without running
sykli graph                # Visualize as Mermaid diagram
sykli delta                # Run only git-affected tasks
sykli delta --from=main    # Compare against branch
sykli watch                # Re-run on file changes

sykli cache stats          # Show cache statistics
sykli cache clean          # Clear cache

sykli report               # Show last run details
sykli history              # List recent runs

sykli daemon start         # Start mesh node
sykli daemon start --labels=gpu,docker
```

---

## How It Works

```
┌─────────────┐     ┌──────────────┐     ┌────────────┐
│  sykli.go   │────▶│  JSON Graph  │────▶│   Engine   │
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

1. **Detect**: Sykli finds `sykli.go`, `sykli.rs`, `sykli.ts`, or `sykli.exs`
2. **Emit**: Runs your SDK file with `--emit` to get a JSON task graph
3. **Execute**: Runs tasks in parallel by dependency level
4. **Cache**: Skips unchanged tasks based on input file hashes

**Why Elixir?** The BEAM VM's distribution primitives let the same code run locally or across a cluster. Your laptop and your CI farm run identical code.

---

## Documentation

- **[ADR Index](docs/adr/)** - Architectural Decision Records
- **[SDK API Design](docs/adr/005-sdk-api.md)** - SDK philosophy
- **[Mesh Networking](docs/adr/013-mesh-swarm-design.md)** - Distributed execution
- **[Node Placement](docs/adr/017-task-placement.md)** - Label-based routing

---

## Project Status

Sykli is **experimental**. We're using it internally but APIs may change.

| Component | Status |
|-----------|--------|
| Core Engine | Stable |
| Go SDK | Stable |
| Rust SDK | Stable |
| TypeScript SDK | Beta |
| Elixir SDK | Stable |
| Local Execution | Stable |
| Container Tasks | Stable |
| Mesh Distribution | Beta |
| K8s Target | Beta |
| Remote Cache | Planned |

**Current version: v0.3.0**

---

## Roadmap

**v0.3.0** (Current)
- Node profiles & labels
- Task requirements for placement
- PlacementError diagnostics

**v0.4.0**
- Remote cache (S3/GCS)
- Cache garbage collection
- Schema-driven SDK codegen

**v0.5.0**
- Hosted dashboard
- Webhook triggers
- GitHub App integration

---

## Contributing

Sykli is open source under the MIT license. Contributions welcome!

```bash
# Run tests
cd core && mix test

# Build binary
mix escript.build
```

---

## Naming

**Sykli** (Finnish: "cycle") - Part of a Finnish tool naming theme for DevOps tools.

---

<div align="center">

**[Get Started](#quick-start)** · **[GitHub](https://github.com/yairfalse/sykli)** · **[Issues](https://github.com/yairfalse/sykli/issues)**

Built in Berlin. Powered by BEAM. No YAML was harmed.

</div>
