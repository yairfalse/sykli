# Sykli Go SDK

CI pipelines defined in Go instead of YAML.

```go
package main

import sykli "sykli.dev/go"

func main() {
    s := sykli.New()
    s.Task("test").Run("go test ./...")
    s.Task("build").Run("go build -o app").After("test")
    s.Emit()
}
```

## Installation

```bash
go get sykli.dev/go
```

## Quick Start

Create a `sykli.go` file in your project root:

```go
//go:build ignore

package main

import sykli "sykli.dev/go"

func main() {
    s := sykli.New()

    s.Task("lint").Run("go vet ./...")
    s.Task("test").Run("go test ./...")
    s.Task("build").
        Run("go build -o ./app").
        After("lint", "test")

    s.Emit()
}
```

Run it:

```bash
sykli run
```

## Core Concepts

### Tasks

Tasks are the basic unit of work. Each task runs a command:

```go
s.Task("test").Run("go test ./...")
```

### Dependencies

Define execution order with `.After()`:

```go
s.Task("deploy").
    Run("./deploy.sh").
    After("build", "test")  // Runs after both complete
```

Independent tasks run in parallel automatically.

### Input-Based Caching

Skip unchanged tasks with `.Inputs()`:

```go
s.Task("test").
    Run("go test ./...").
    Inputs("**/*.go", "go.mod", "go.sum")
```

If the files matching these patterns haven't changed since the last run, the task is skipped.

### Outputs

Declare task outputs for artifact passing:

```go
s.Task("build").
    Run("go build -o ./app").
    Output("binary", "./app")
```

### Conditional Execution

Run tasks based on branch, tag, or event:

```go
// String-based conditions
s.Task("deploy").
    Run("./deploy.sh").
    When("branch == 'main'")

// Type-safe conditions (compile-time checked)
s.Task("release").
    Run("./release.sh").
    WhenCond(Branch("main").Or(Tag("v*")))
```

Available condition builders:
- `Branch("main")` / `Branch("feature/*")`
- `Tag("v*")` / `HasTag()`
- `Event("push")` / `Event("pull_request")`
- `InCI()`
- `Not(condition)`, `And()`, `Or()`

## Templates

Templates eliminate repetition. Define once, use everywhere:

```go
// Define a template with common settings
golang := s.Template("golang").
    Container("golang:1.21").
    Mount(src, "/src").
    MountCache(goModCache, "/go/pkg/mod").
    Workdir("/src")

// Tasks inherit from the template
s.Task("lint").From(golang).Run("go vet ./...")
s.Task("test").From(golang).Run("go test ./...")
s.Task("build").From(golang).Run("go build -o ./app")
```

Task-specific settings override template settings.

## Containers

Run tasks in isolated containers:

```go
src := s.Dir(".")
cache := s.Cache("go-mod")

s.Task("test").
    Container("golang:1.21").
    Mount(src, "/src").
    MountCache(cache, "/go/pkg/mod").
    Workdir("/src").
    Run("go test ./...")
```

### Convenience Methods

```go
// Mount current dir to /work and set workdir
s.Task("test").
    Container("node:20").
    MountCwd().
    Run("npm test")

// Mount to custom path
s.Task("build").
    Container("golang:1.21").
    MountCwdAt("/app").
    Run("go build")
```

## Composition

### Parallel Groups

Group tasks that run concurrently:

```go
checks := s.Parallel("checks",
    s.Task("lint").Run("go vet ./..."),
    s.Task("test").Run("go test ./..."),
    s.Task("fmt").Run("gofmt -l ."),
)

// Build depends on all checks passing
s.Task("build").
    Run("go build -o app").
    AfterGroup(checks)
```

### Chains

Create sequential pipelines:

```go
test := s.Task("test").Run("go test ./...")
build := s.Task("build").Run("go build -o app")
deploy := s.Task("deploy").Run("./deploy.sh")

// test -> build -> deploy
s.Chain(test, build, deploy)
```

### Artifact Passing

Pass outputs between tasks with `InputFrom`:

```go
s.Task("build").
    Run("go build -o /out/app").
    Output("binary", "/out/app")

// Automatically depends on "build", receives the artifact
s.Task("package").
    Run("docker build -t myapp .").
    InputFrom("build", "binary", "./app")
```

## Matrix Builds

Run tasks across multiple configurations:

```go
// Simple matrix - generates test-1.21, test-1.22, test-1.23
s.Matrix("test", []string{"1.21", "1.22", "1.23"}, func(version string) *Task {
    return s.Task("test-go-"+version).
        Container("golang:"+version).
        MountCwd().
        Run("go test ./...")
})

// Map matrix - generates deploy-staging, deploy-prod
s.MatrixMap("deploy", map[string]string{
    "staging": "staging.example.com",
    "prod":    "prod.example.com",
}, func(env, host string) *Task {
    return s.Task("deploy-"+env).
        Run("deploy --host " + host)
})
```

## Service Containers

Run background services for integration tests:

```go
s.Task("test").
    Container("golang:1.21").
    Service("postgres:15", "db").
    Service("redis:7", "cache").
    Env("DATABASE_URL", "postgres://db:5432/test").
    Env("REDIS_URL", "redis://cache:6379").
    Run("go test ./...")
```

Services are accessible by their name as hostname.

## Secrets

Declare secrets your task needs:

```go
// Simple secret (from environment)
s.Task("deploy").
    Secret("DEPLOY_TOKEN").
    Run("./deploy.sh")

// Typed secrets with explicit source
s.Task("deploy").
    SecretFrom("GITHUB_TOKEN", FromEnv("GH_TOKEN")).
    SecretFrom("DB_PASSWORD", FromVault("secret/db#password")).
    SecretFrom("API_KEY", FromFile("/run/secrets/api-key")).
    Run("./deploy.sh")
```

## Retry & Timeout

Add resilience to flaky tasks:

```go
s.Task("flaky-test").
    Run("./integration-test.sh").
    Retry(3).      // Retry up to 3 times on failure
    Timeout(300)   // 5 minute timeout
```

## Kubernetes Execution

Run tasks on Kubernetes:

```go
// Pipeline-level K8s defaults
s := sykli.New(sykli.WithK8sDefaults(sykli.K8sTaskOptions{
    Namespace: "ci-jobs",
    Resources: sykli.K8sResources{Memory: "2Gi"},
}))

// Task-specific K8s settings
s.Task("train-model").
    Container("pytorch/pytorch:2.0").
    Run("python train.py").
    K8s(sykli.K8sTaskOptions{
        GPU: 1,
        Resources: sykli.K8sResources{Memory: "32Gi"},
        NodeSelector: map[string]string{"gpu": "nvidia-a100"},
    })

// Hybrid: some tasks local, some on K8s
s.Task("test").Run("go test").Target("local")
s.Task("train").Run("python train.py").Target("k8s")
```

## Language Presets

Convenience methods for common patterns:

```go
s := sykli.New()

// Go preset
s.Go().Test()                     // go test ./...
s.Go().Lint()                     // go vet ./...
s.Go().Build("./app").After("test", "lint")

s.Emit()
```

## Dry Run / Explain

See what would run without executing:

```go
s.Explain(&sykli.ExplainContext{
    Branch: "feature/foo",
    Tag:    "",
    CI:     true,
})

// Output:
// Pipeline Execution Plan
// =======================
// 1. test
//    Command: go test ./...
//
// 2. build (after: test)
//    Command: go build
//
// 3. deploy (after: build) [SKIPPED: branch is 'feature/foo', not 'main']
//    Command: kubectl apply
//    Condition: branch == 'main'
```

## Examples

See the [examples directory](../../examples/) for complete working examples:

- `go-project/` - Basic Go pipeline with containers and caching
- `go-project-v2/` - Templates, parallel groups, and artifact passing

## API Reference

See [REFERENCE.md](./REFERENCE.md) for the complete API documentation.

## License

MIT
