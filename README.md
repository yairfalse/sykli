# sykli

**CI in your language. No YAML. No DSL. Just code.**

```go
// sykli.go — this IS your CI
package main

import "sykli.dev/go"

func main() {
    s := sykli.New()

    // Define resources
    src := s.Dir(".")
    goModCache := s.Cache("go-mod")

    // Tasks run in containers with caches
    s.Task("test").
        Container("golang:1.21").
        Mount(src, "/src").
        MountCache(goModCache, "/go/pkg/mod").
        Workdir("/src").
        Run("go test ./...")

    s.Task("build").
        Container("golang:1.21").
        Mount(src, "/src").
        MountCache(goModCache, "/go/pkg/mod").
        Workdir("/src").
        Env("CGO_ENABLED", "0").
        Run("go build -o ./app .").
        Output("binary", "./app").
        After("test")

    s.Emit()
}
```

Run `sykli`. Done.

---

## Why

YAML is not a programming language. Stop pretending it is.

- **No YAML** — your CI config is real code
- **No DSL** — use your language's full power
- **No magic** — SDK emits JSON, core executes it
- **Local first** — same behavior on your machine and CI

---

## How It Works

```
sykli.go  →  JSON task graph  →  Elixir core  →  parallel execution
   SDK           stdout            engine
```

1. Write `sykli.go` (or `.rs`, `.ts`)
2. Core runs it, gets task graph as JSON
3. Core executes tasks in parallel by dependency level

---

## Install

```bash
# Coming soon
brew install sykli
```

For now, clone and run with Mix:

```bash
cd core && mix run -e 'Sykli.run("/path/to/your/project")'
```

---

## SDK

### Simple Tasks

```go
s := sykli.New()

s.Task("test").Run("go test ./...")
s.Task("lint").Run("go vet ./...")
s.Task("build").Run("go build -o app").After("test", "lint")

s.Emit()
```

### Container Tasks

```go
s := sykli.New()

// Resources
src := s.Dir(".")
nodeModules := s.Cache("node-modules")

// Run in container with mounted source and cache
s.Task("test").
    Container("node:20").
    Mount(src, "/app").
    MountCache(nodeModules, "/app/node_modules").
    Workdir("/app").
    Run("npm test")

s.Emit()
```

### Inputs & Outputs

```go
s.Task("build").
    Run("go build -o ./dist/app").
    Inputs("**/*.go", "go.mod").   // Cache invalidation
    Output("binary", "./dist/app") // Named outputs

s.Emit()
```

### Presets

```go
s := sykli.New()

s.Go().Test()
s.Go().Lint()
s.Go().Build("./app").After("test", "lint")

s.Emit()
```

---

## Features

| Feature | Status |
|---------|--------|
| Go SDK | Done |
| Parallel execution | Done |
| Container tasks | Done |
| Volume mounts | Done |
| Cache mounts | Done |
| Content-addressed caching | Done |
| GitHub commit status | Done |
| Rust/TypeScript SDKs | Planned |
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
                    │                          │                          ▲
                    └──────────────────────────┴──────────────────────────┘
                                         parallel
```

Elixir for a reason: OTP distribution means local and remote execution are the same system at different scales.

---

## Name

*Sykli* — Finnish for "cycle".

---

## License

MIT
