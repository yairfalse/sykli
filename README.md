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

CI configuration files started simple but grew into pseudo-programming languages. YAML with templating, custom DSLs with conditionals, proprietary scripting layers. The result: you're programming, but in a language designed for configuration.

Sykli takes a different approach. Your CI definition is a program in your language—Go, Rust, TypeScript. It runs, emits a task graph as JSON, and an executor runs the tasks in parallel. No interpretation layer. No config-language barriers. Just code that describes what to build and run.

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

1. Write `sykli.go` (or `.rs`, `.ts`, `.exs`)
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

### Elixir SDK

```elixir
# sykli.exs
Mix.install([{:sykli, "~> 0.1"}])

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
```

With presets:

```elixir
pipeline do
  mix_deps()
  mix_test()
  mix_credo()
  mix_format()
end
```

---

## Status

> ⚠️ **Experimental** — Sykli is an experimental project, primarily used internally by us. APIs may change. Use at your own risk, but feel free to try it out!

---

## Features

| Feature | Status |
|---------|--------|
| Go SDK | ✅ Done |
| Rust SDK | ✅ Done |
| Elixir SDK | ✅ Done ([hex.pm/packages/sykli](https://hex.pm/packages/sykli)) |
| Parallel execution | ✅ Done |
| Container tasks | ✅ Done |
| Volume mounts | ✅ Done |
| Cache mounts | ✅ Done |
| Content-addressed caching | ✅ Done |
| GitHub commit status | ✅ Done |
| Distributed events (ULID) | ✅ Done |
| AHTI observability | ✅ Ready |
| TypeScript SDK | Planned |
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

## Distributed Observability

Every execution emits events with ULID-based IDs for causality tracking:

```
run_started    │ 01KCSVXCXAWCXEEW1DHK9YWW6V │ {project: ".", tasks: ["test", "build"]}
task_started   │ 01KCSVXCXAWCXEEW1DHK9YWW6W │ {task: "test"}
task_completed │ 01KCSVXCXEKRR73QMRVDA9BVWP │ {task: "test", outcome: :success}
run_completed  │ 01KCSVXCXEKRR73QMRVDA9BVWQ │ {outcome: :success}
```

### Why ULIDs?

- **Time-sortable**: Lexicographic order = temporal order
- **Monotonic**: Events in same millisecond are strictly ordered
- **Causality**: Parent event ID < child event ID always

### Event Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Worker    │────▶│  PubSub     │────▶│ Coordinator │
│   Node      │     │  (BEAM)     │     │   Node      │
└─────────────┘     └─────────────┘     └─────────────┘
      │                                        │
      │  Event structs with ULIDs              │
      │  flow across the cluster               ▼
      │                                 ┌─────────────┐
      └────────────────────────────────▶│   AHTI      │
                                        │ (optional)  │
                                        └─────────────┘
```

Workers emit events → Reporter buffers/forwards → Coordinator aggregates.

No external message queue needed—OTP distribution handles it.

### AHTI Integration

Events are structured for [AHTI](https://github.com/yairfalse/ahti) causality correlation:

```elixir
event = Sykli.Events.Event.new(:task_completed, run_id, %{
  task_name: "build",
  outcome: :success
})

# Convert to AHTI format
ahti_json = Sykli.Events.Event.to_ahti_json(event, "prod-cluster")
```

See [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md) for full schema mapping.

---

## Name

*Sykli* — Finnish for "cycle".

---

## License

MIT
