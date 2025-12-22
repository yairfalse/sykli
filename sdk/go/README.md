# sykli

CI pipelines defined in Go instead of YAML.

## Quick Start

```go
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()

    s.Task("test").Run("go test ./...")
    s.Task("lint").Run("go vet ./...")
    s.Task("build").
        Run("go build -o app").
        After("test", "lint")

    s.Emit()
}
```

## Features

- **Task dependencies** - Define execution order with `.After()`
- **Input-based caching** - Skip unchanged tasks with `.Inputs()`
- **Parallel execution** - Independent tasks run concurrently
- **Cycle detection** - Catches dependency cycles before execution
- **Conditional execution** - Run tasks based on branch/tag with `.When()`
- **Matrix builds** - Run tasks across multiple configurations
- **Service containers** - Background services for integration tests
- **Retry & timeout** - Resilience for flaky tasks

## With Caching

```go
s.Task("test").
    Run("go test ./...").
    Inputs("**/*.go", "go.mod")
```

## Conditional Execution

```go
s.Task("deploy").
    Run("./deploy.sh").
    When("branch == 'main'").
    Secret("DEPLOY_TOKEN")
```

## Matrix Builds

```go
s.Task("test").
    Run("go test ./...").
    Matrix("go_version", "1.21", "1.22", "1.23")
```

## Container Tasks

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

## Go Preset

```go
s := sykli.New()
s.Go().Test()
s.Go().Lint()
s.Go().Build("./app").After("test", "lint")
s.Emit()
```

## License

MIT
