# sykli

**CI in your language. No YAML. No DSL. Just code.**

## What is Sykli?

Sykli lets you define CI pipelines in Go, Rust, or Elixir instead of YAML. Your pipeline is a real program that outputs a task graph, which Sykli executes in parallel.

```go
// sykli.go — your CI config is just Go code
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()

    s.Task("test").Run("go test ./...")
    s.Task("lint").Run("go vet ./...")
    s.Task("build").Run("go build -o app").After("test", "lint")

    s.Emit()
}
```

Run `sykli` in your project directory. That's it.

---

## Quick Start

**1. Install sykli:**

```bash
curl -fsSL https://raw.githubusercontent.com/yairfalse/sykli/main/install.sh | bash
```

**2. Create `sykli.go` in your project:**

```go
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()
    s.Task("test").Run("echo 'Running tests...'")
    s.Task("build").Run("echo 'Building...'").After("test")
    s.Emit()
}
```

**3. Run it:**

```bash
$ sykli

── Level with 1 task(s) ──
▶ test  echo 'Running tests...'
  Running tests...
✓ test  2ms

── Level with 1 task(s) ──
▶ build  echo 'Building...'
  Building...
✓ build  1ms

─────────────────────────────────────────
✓ 2 passed in 48ms
```

Tasks run in parallel when they have no dependencies. Tasks with dependencies wait for them to complete.

---

## Why Not YAML?

CI config files started simple, then grew conditional logic, templating, and variable substitution. Now you're programming in YAML—a language designed for configuration, not logic.

Sykli flips this: **write your CI in a real programming language.** You get:

- **Type checking** — catch errors before running
- **IDE support** — autocomplete, go-to-definition, refactoring
- **Abstraction** — functions, loops, conditionals that actually work
- **Testing** — unit test your pipeline logic
- **Local execution** — same behavior on your machine and CI

---

## How It Works

```
sykli.go  ──run──▶  JSON task graph  ──▶  parallel execution
   SDK                  stdout              Elixir engine
```

1. Sykli detects your SDK file (`sykli.go`, `sykli.rs`, or `sykli.exs`)
2. Runs it to get a JSON task graph
3. Executes tasks in parallel by dependency level
4. Caches results based on input file hashes

---

## Error Handling

Sykli catches problems before execution. Here's what happens with a dependency cycle:

```go
s.Task("a").Run("echo a").After("b")
s.Task("b").Run("echo b").After("a")  // cycle: a → b → a
s.Emit()
```

```bash
$ sykli
ERR dependency cycle detected  cycle=["a","b","a"]
```

And when a task fails:

```bash
$ sykli

── Level with 1 task(s) ──
▶ test  exit 1
✗ test  (exit 1)
✗ test failed, stopping

─────────────────────────────────────────
✗ 1 failed in 12ms
```

---

## SDK Examples

### Caching with Inputs

Tasks with inputs are cached. If input files haven't changed, the task is skipped:

```go
s.Task("test").
    Run("go test ./...").
    Inputs("**/*.go", "go.mod")
```

```bash
$ sykli
⊙ test  CACHED

✓ 1 passed in 3ms
```

### Dependencies

```go
s.Task("test").Run("go test ./...")
s.Task("lint").Run("go vet ./...")
s.Task("build").Run("go build -o app").After("test", "lint")
```

`test` and `lint` run in parallel. `build` waits for both.

### Conditional Execution

```go
s.Task("deploy").
    Run("./deploy.sh").
    When("branch == 'main'").
    Secret("DEPLOY_TOKEN")
```

### Retry Flaky Tasks

```go
s.Task("integration").
    Run("./integration-tests.sh").
    Retry(3).
    Timeout(300)
```

### Matrix Builds

```go
s.Task("test").
    Run("go test ./...").
    Matrix("go_version", "1.21", "1.22", "1.23")
```

Expands to `test[go_version=1.21]`, `test[go_version=1.22]`, `test[go_version=1.23]`.

### Service Containers

```go
s.Task("test").
    Run("go test ./...").
    Service("postgres:15", "db").
    Service("redis:7", "cache")
```

---

## All Three SDKs

### Go

```go
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()
    s.Go().Test()
    s.Go().Lint()
    s.Go().Build("./app").After("test", "lint")
    s.Emit()
}
```

### Rust

```rust
use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.rust().test();
    p.rust().lint();
    p.rust().build("target/release/app").after(&["test", "lint"]);
    p.emit();
}
```

### Elixir

```elixir
Mix.install([{:sykli, "~> 0.1"}])

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
| Service containers | ✅ |
| Container tasks | ✅ |
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
                    │                          │                          ▲
                    └──────────────────────────┴──────────────────────────┘
                                         parallel
```

The engine is written in Elixir/OTP. Why? The same code that runs locally can distribute across a cluster—local and remote execution are the same system at different scales.

---

## Status

> **Experimental** — Sykli is used internally by us. APIs may change. Use at your own risk.

---

## Name

*Sykli* — Finnish for "cycle".

---

## License

MIT
