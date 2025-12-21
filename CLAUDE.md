# SYKLI: CI in Your Language

**SYKLI = Cycle (Finnish) — Dagger meets CircleCI, but simpler**

---

## WHAT IS SYKLI

No YAML. No config files. No DSL.

Your CI config IS code in your language:

```go
// sykli.go — this IS your CI config
package main

import "sykli.dev/go"

func main() {
    sykli.Test()
    sykli.Lint()
    sykli.Build("./app")
    sykli.MustEmit()
}
```

That's it. Run `sykli` and it works.

---

## HOW IT WORKS

```
sykli.go  ──emit──▶  JSON task graph  ──▶  Elixir core  ──▶  parallel execution
```

1. You write `sykli.go` (or `.rs`, `.ts`) — real code, not config
2. Core runs it with `--emit` → gets JSON task graph
3. Core executes tasks in parallel by dependency level
4. Done

---

## PROJECT STRUCTURE

```
sykli/
├── core/                      # Elixir — the brain
│   └── lib/sykli/
│       ├── detector.ex        # finds sykli.go, runs --emit
│       ├── graph.ex           # parses JSON, topo sort
│       └── executor.ex        # parallel execution
├── sdk/go/                    # Go SDK — thin, typed
│   └── sykli.go
└── examples/go-project/       # working example
    └── sykli.go
```

---

## SDK INTERFACE

```go
sykli.Test()            // go test ./...
sykli.Lint()            // go vet ./...
sykli.Build("./app")    // go build -o ./app
sykli.Run("cmd")        // arbitrary command
sykli.After("task")     // depends on task
sykli.MustEmit()        // output JSON (call last)
```

---

## ELIXIR CORE

**Key modules:**
- `Sykli.Detector` — finds `sykli.go`, runs `go run sykli.go --emit`
- `Sykli.Graph` — parses JSON, topological sort
- `Sykli.Executor` — runs tasks in parallel by level

**Parallelism:**
- Level 0: no deps → run together
- Level 1: depends on level 0 → run after level 0 completes
- Uses `Task.async` + `Task.await_many`

**Important:** Don't alias `Sykli.Graph.Task` — shadows Elixir's `Task` module.

---

## RUN IT

```bash
cd core
mix run -e 'Sykli.run("/path/to/project")'
```

Output:
```
── Level with 2 task(s) ──
▶ lint  go vet ./...
▶ test  go test ./...
✓ lint
✓ test

── Level with 1 task(s) ──
▶ build  go build -o ./app
✓ build
```

---

## NEXT

- [x] Content-addressed caching (local)
- [ ] Remote cache backend (S3/GCS)
- [x] Rust SDK
- [x] Elixir SDK
- [x] Build escript binary
- [x] GitHub status API
- [x] Distributed observability
- [ ] Publish SDKs (crates.io, hex.pm)

---

## NOT

- Not YAML
- Not a new DSL
- Not Bazel
- Not complicated

**Your language. Your CI.**
