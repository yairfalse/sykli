# ADR-005: SDK API Design

**Status:** Accepted
**Date:** 2024-12-03

---

## Context

How should users write their `sykli.go` files? What's the API?

## Decision

**Client style with explicit instance.**

```go
func main() {
    s := sykli.New()

    s.RequireEnv("GITHUB_TOKEN")
    s.GitHub().PerTaskStatus()

    s.Task("test").Run("go test ./...")
    s.Task("lint").Run("go vet ./...")
    s.Task("build").Run("go build -o app").After("test", "lint")

    s.Emit()
}
```

---

## Why This Style

| Style | Example | Verdict |
|-------|---------|---------|
| Top-level functions | `sykli.Task()` | Hidden global state |
| Callback context | `sykli.Pipeline(func(p))` | Unnecessary nesting |
| **Client instance** | `s := sykli.New()` | Explicit, testable, like Dagger |

Matches patterns from:
- **Dagger**: `client, _ := dagger.Connect(ctx)`
- **Ilmari**: `ilmari.Run(t, func(ctx))`
- **Seppo**: `ctx: TestContext`

---

## Full API Reference

### Pipeline

```go
// Create pipeline
s := sykli.New()

// Emit JSON (call at end)
s.Emit()        // writes to stdout, exits 0
s.MustEmit()    // same, panics on error
```

### Environment

```go
// Require env vars (fail fast if missing)
s.RequireEnv("GITHUB_TOKEN", "DEPLOY_KEY")
```

### Tasks

```go
// Create task
t := s.Task("name")

// Set command (required)
t.Run("go test ./...")

// Dependencies
t.After("test", "lint")      // depends on these tasks

// Timeout (default: 300s)
t.Timeout(5 * time.Minute)

// Failure handling (default: Stop)
t.OnFailure(sykli.Stop)      // stop pipeline
t.OnFailure(sykli.Continue)  // continue other tasks
t.OnFailure(sykli.Retry(3))  // retry N times

// Inputs for caching
t.Inputs("**/*.go", "go.mod", "go.sum")

// Outputs (artifacts)
t.Outputs("./dist/app", "./coverage.html")

// Full example
s.Task("build").
    Run("go build -o ./dist/app").
    After("test", "lint").
    Timeout(10 * time.Minute).
    OnFailure(sykli.Stop).
    Inputs("**/*.go", "go.mod").
    Outputs("./dist/app")
```

### Presets (convenience)

```go
// Go presets
s.Go().Test()       // → go test ./...
s.Go().Lint()       // → go vet ./...
s.Go().Build("app") // → go build -o app

// Rust presets (future)
s.Rust().Test()     // → cargo test
s.Rust().Lint()     // → cargo clippy
s.Rust().Build()    // → cargo build --release

// Node presets (future)
s.Node().Test()     // → npm test
s.Node().Lint()     // → npm run lint
s.Node().Build()    // → npm run build
```

### GitHub Integration

```go
// Enable per-task status
s.GitHub().PerTaskStatus()

// With custom prefix (default: "ci/sykli")
s.GitHub().PerTaskStatus("build/myapp")

// Requires: GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA
```

---

## Fluent Chaining

All task methods return the task for chaining:

```go
s.Task("deploy").
    Run("./deploy.sh").
    After("build").
    Timeout(15 * time.Minute).
    OnFailure(sykli.Retry(2))
```

---

## Complete Example

```go
//go:build ignore

package main

import (
    "time"
    "sykli.dev/go"
)

func main() {
    s := sykli.New()

    // Config
    s.RequireEnv("GITHUB_TOKEN", "DEPLOY_KEY")
    s.GitHub().PerTaskStatus()

    // Tasks
    s.Task("test").
        Run("go test ./...").
        Timeout(5 * time.Minute).
        Inputs("**/*.go", "go.mod", "go.sum")

    s.Task("lint").
        Run("golangci-lint run").
        Timeout(2 * time.Minute).
        Inputs("**/*.go")

    s.Task("build").
        Run("go build -o ./dist/app ./cmd/app").
        After("test", "lint").
        Inputs("**/*.go", "go.mod", "go.sum").
        Outputs("./dist/app")

    s.Task("deploy").
        Run("./scripts/deploy.sh").
        After("build").
        OnFailure(sykli.Retry(2))

    s.Emit()
}
```

---

## JSON Output

The above emits:

```json
{
  "version": "1",
  "required_env": ["GITHUB_TOKEN", "DEPLOY_KEY"],
  "github": {
    "enabled": true,
    "per_task_status": true,
    "context_prefix": "ci/sykli"
  },
  "tasks": [
    {
      "name": "test",
      "command": "go test ./...",
      "inputs": ["**/*.go", "go.mod", "go.sum"],
      "depends_on": [],
      "timeout": 300,
      "on_failure": "stop"
    },
    {
      "name": "lint",
      "command": "golangci-lint run",
      "inputs": ["**/*.go"],
      "depends_on": [],
      "timeout": 120,
      "on_failure": "stop"
    },
    {
      "name": "build",
      "command": "go build -o ./dist/app ./cmd/app",
      "inputs": ["**/*.go", "go.mod", "go.sum"],
      "outputs": ["./dist/app"],
      "depends_on": ["test", "lint"],
      "timeout": 300,
      "on_failure": "stop"
    },
    {
      "name": "deploy",
      "command": "./scripts/deploy.sh",
      "depends_on": ["build"],
      "timeout": 300,
      "on_failure": "retry:2"
    }
  ]
}
```

---

## Error Handling

```go
s := sykli.New()

// These validate at Emit() time:
// - Duplicate task names → error
// - Unknown task in After() → error
// - Missing RequireEnv vars → error (when running, not emitting)
// - No tasks defined → error

s.Emit() // validates and outputs JSON
```

---

## Future: Multi-language SDKs

Same API, different languages:

**Rust**
```rust
fn main() {
    let s = sykli::new();

    s.require_env(&["GITHUB_TOKEN"]);
    s.github().per_task_status();

    s.task("test").run("cargo test");
    s.task("build").run("cargo build --release").after(&["test"]);

    s.emit();
}
```

**TypeScript**
```typescript
const s = sykli.create()

s.requireEnv("GITHUB_TOKEN")
s.github().perTaskStatus()

s.task("test").run("npm test")
s.task("build").run("npm run build").after("test")

s.emit()
```

---

**Explicit. Fluent. Familiar.**
