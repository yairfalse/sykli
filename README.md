# sykli

**CI in your language. No YAML. No DSL. Just code.**

```go
// sykli.go — this IS your CI
package main

import "sykli.dev/go"

func main() {
    s := sykli.New()

    s.Task("test").Run("go test ./...")
    s.Task("lint").Run("go vet ./...")
    s.Task("build").Run("go build -o app").After("test", "lint")

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

---

## SDK

```go
s := sykli.New()

// Environment
s.RequireEnv("GITHUB_TOKEN", "DEPLOY_KEY")

// GitHub integration
s.GitHub().PerTaskStatus()

// Tasks
s.Task("test").
    Run("go test ./...").
    Timeout(5 * time.Minute).
    Inputs("**/*.go", "go.mod")

s.Task("build").
    Run("go build -o ./dist/app").
    After("test", "lint").
    Outputs("./dist/app")

s.Task("deploy").
    Run("./deploy.sh").
    After("build").
    OnFailure(sykli.Retry(2))

s.Emit()
```

---

## Architecture

Elixir core for a reason:

| Local | Remote |
|-------|--------|
| Single node | Multiple nodes |
| Same code | Same code |

OTP distribution means local and remote execution are the same system at different scales. No gRPC. No separate worker binaries. Just Elixir processes.

---

## Status

Working. Used on real projects.

- [x] Go SDK
- [x] Elixir core (detector, graph, executor)
- [x] Parallel execution by dependency level
- [x] GitHub per-task commit status
- [x] Content-addressed caching
- [ ] Published SDK (`sykli.dev/go`)
- [ ] Rust/TypeScript SDKs
- [ ] Remote execution

---

## Name

*Sykli* — Finnish for "cycle". Part of a toolchain with [rauta](https://github.com/yourorg/rauta), seppo, and ilmari.

---

## License

MIT
