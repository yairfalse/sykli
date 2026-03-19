<div align="center">

# SYKLI

**CI pipelines as real code. AI reads the results. Supply chain signed.**

[![GitHub Release](https://img.shields.io/github/v/release/yairfalse/sykli?style=flat-square&color=blue)](https://github.com/yairfalse/sykli/releases)
[![crates.io](https://img.shields.io/crates/v/sykli?style=flat-square&color=orange)](https://crates.io/crates/sykli)
[![Hex.pm](https://img.shields.io/hexpm/v/sykli?style=flat-square&color=purple)](https://hex.pm/packages/sykli)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg?style=flat-square)](LICENSE)

</div>

```go
// sykli.go — your CI config is a Go program
s := sykli.New()
s.Task("test").Run("go test ./...").Inputs("**/*.go")
s.Task("build").Run("go build -o app").After("test")
s.Emit()
```

```
$ sykli
▶ test   go test ./...
✓ test   124ms

▶ build  go build -o app
✓ build  1.2s

✓ 2 passed in 1.4s
```

No YAML. No DSL. No vendor lock-in. Write pipelines in **Go**, **Rust**, **TypeScript**, **Elixir**, or **Python**.

---

## Three things that make Sykli different

### 1. Pipelines are real code

Not YAML with string interpolation hacks. Real variables, real functions, real type checking.

```go
// Templates — define once, reuse everywhere
golang := s.Template("golang").Container("golang:1.22").Mount(src, "/src")

s.Task("test").From(golang).Run("go test ./...")
s.Task("lint").From(golang).Run("go vet ./...")
s.Task("build").From(golang).Run("go build -o app").After("test", "lint")
```

### 2. AI reads the output — no log parsing

Every run writes structured context to `.sykli/`. When your build fails, AI tools get:

```json
{
  "error": {
    "what_failed": "task 'test' command: go test ./...",
    "why_it_matters": "blocks build, deploy",
    "possible_causes": ["pkg/auth/handler.go changed and matches test inputs"],
    "suggested_fix": "check recent changes to pkg/auth/"
  },
  "reasoning": {
    "summary": "test failed — pkg/auth/handler.go changed and matches task inputs",
    "confidence": 0.8
  }
}
```

No scraping logs. No regex. Structured data from birth.

### 3. Supply chain provenance is automatic

Every run that produces artifacts generates [SLSA v1.0](https://slsa.dev) provenance attestations. Zero configuration.

```
.sykli/attestation.json          # Per-run DSSE envelope (in-toto/SLSA v1)
.sykli/attestations/build.json   # Per-task envelopes for artifact registries
```

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/yairfalse/sykli/main/install.sh | bash
```

Or [download a binary](https://github.com/yairfalse/sykli/releases/latest) for macOS (Apple Silicon / Intel) or Linux (x86_64 / ARM64).

<details>
<summary>Build from source</summary>

```bash
git clone https://github.com/yairfalse/sykli.git && cd sykli/core
mix deps.get && mix escript.build
sudo mv sykli /usr/local/bin/
```
Requires Elixir 1.14+.
</details>

---

## Quick start

```bash
sykli init      # auto-detects language, generates sykli.go / .rs / .ts / .exs / .py
sykli           # run the pipeline
```

### Pick your SDK

| Language | Install | File |
|----------|---------|------|
| **Go** | `go get github.com/yairfalse/sykli/sdk/go@latest` | `sykli.go` |
| **Rust** | `sykli = "0.5"` in Cargo.toml | `sykli.rs` |
| **TypeScript** | `npm install sykli` | `sykli.ts` |
| **Elixir** | `{:sykli_sdk, "~> 0.5.1"}` in mix.exs | `sykli.exs` |
| **Python** | `pip install sykli` | `sykli.py` |

All SDKs share the same API surface. The file must be in the project root.

---

## What you can do

### Content-addressed caching

```go
s.Task("test").Run("go test ./...").Inputs("**/*.go", "go.mod")
// Second run: ⊙ test  CACHED (no input changes)
```

### Docker containers

```go
s.Task("test").
    Container("golang:1.22").
    Mount(s.Dir("."), "/src").
    MountCache(s.Cache("go-mod"), "/go/pkg/mod").
    Run("go test ./...")
```

### Matrix builds

```go
s.Task("test").Run("go test ./...").Matrix("go", "1.21", "1.22", "1.23")
// Expands to: test[go=1.21], test[go=1.22], test[go=1.23]
```

### Delta builds

```bash
sykli delta                # only tasks affected by git changes
sykli delta --from=main    # compare against branch
```

### Gate tasks (approval points)

```go
s.Gate("approve-deploy").Message("Deploy to production?").Strategy("prompt")
s.Task("deploy").Run("./deploy.sh").After("approve-deploy")
```

### Artifact passing

```go
build := s.Task("build").Run("go build -o /out/app").Output("binary", "/out/app")
s.Task("deploy").InputFrom(build, "binary", "/app/bin").Run("./deploy.sh /app/bin")
```

### Node placement

```go
s.Task("train").Requires("gpu").Run("python train.py")
```

```bash
SYKLI_LABELS=gpu,team:ml sykli daemon start   # expose this machine to the mesh
sykli --mesh                                    # distribute work across nodes
```

### Conditional execution

```go
s.Task("deploy").Run("./deploy.sh").When("branch == 'main'").Secret("DEPLOY_TOKEN")
```

---

## How it works

```
sykli.go ──emit──▶ JSON task graph ──▶ Elixir engine ──▶ .sykli/ (AI context)
   SDK              (stdout)                  │
                                    ┌─────────┼─────────┐
                                    ▼         ▼         ▼
                                 Target    Executor   Occurrence
                                (where)    (how)     (what happened)
```

1. **Detect** — finds `sykli.*` in the current directory
2. **Emit** — runs your SDK file to get a JSON task graph
3. **Execute** — parallel by dependency level, with caching and retries
4. **Observe** — writes structured occurrences + SLSA attestations to `.sykli/`

The engine runs on the BEAM VM. Same code on your laptop, in Docker, on Kubernetes, or across a mesh cluster.

---

## CLI

```bash
sykli                     # run pipeline
sykli --filter=test       # run matching tasks
sykli --timeout=5m        # per-task timeout
sykli --mesh              # distribute across mesh
sykli --target=k8s        # run on Kubernetes

sykli init                # generate SDK file
sykli validate            # check without running
sykli delta               # git-affected tasks only
sykli watch               # re-run on file changes
sykli explain             # show last run (AI-readable)
sykli graph               # mermaid diagram
sykli verify              # cross-platform verification
sykli history             # recent runs
sykli cache stats         # cache hit rates
sykli daemon start        # start mesh node
sykli mcp                 # MCP server for AI tools
```

---

## Project status

| Component | Status |
|-----------|--------|
| Core Engine, Go/Rust/TS/Elixir SDKs, Local Execution, Containers, AI Context | **Stable** |
| Python SDK, Mesh Distribution, K8s Target, Gates, SLSA, Remote Cache (S3) | **Beta** |

---

## Contributing

MIT licensed. 1100+ tests.

```bash
cd core && mix test          # unit + integration tests
test/blackbox/run.sh         # 84 black-box test cases
```

---

<div align="center">

**Sykli** (Finnish: *cycle*) — built in Berlin, powered by BEAM.

**[Install](#install)** · **[Docs](docs/adr/)** · **[Issues](https://github.com/yairfalse/sykli/issues)**

</div>
