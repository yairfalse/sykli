# ADR-009: Sykli Modules — Reusable Pipeline Components

**Status:** Proposed
**Date:** 2025-12-26

---

## Context

CircleCI Orbs are popular because they encapsulate common patterns:
```yaml
orbs:
  node: circleci/node@5.0.0
jobs:
  build:
    executor: node/default
    steps:
      - node/install-packages
      - run: npm test
```

But Orbs have a fundamental problem: **YAML composition is fragile**.

Sykli has a massive advantage: **real code**. Multi-language SDKs mean Modules can be:
- Type-safe (compile-time errors)
- Documented (native tooling)
- Tested (unit tests)
- Versioned (package managers)

---

## Decision

**Build Sykli Modules as native packages in each SDK language.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    SYKLI MODULES PHILOSOPHY                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Modules are NOT configuration templates.                      │
│   Modules ARE code libraries.                                   │
│                                                                 │
│   - Go modules → Go packages                                    │
│   - Elixir modules → Hex packages                               │
│   - Rust modules → Crates                                       │
│   - TypeScript modules → npm packages                           │
│                                                                 │
│   Type safety. Documentation. Testing. Versioning.              │
│   Everything you expect from a library.                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Module Anatomy

### Go Module Example

```go
// Package sykli_docker provides Docker build patterns
package sykli_docker

import "github.com/sykli-io/sykli-go"

// BuildAndPush creates tasks for building and pushing Docker images
type BuildAndPush struct {
    // Image name (required)
    Image string

    // Dockerfile path (default: "Dockerfile")
    Dockerfile string

    // Build context (default: ".")
    Context string

    // Build arguments
    BuildArgs map[string]string

    // Target to run on (user provides)
    Target sykli.Target

    // When to run (user provides)
    Condition sykli.Condition

    // Push to registry (default: true on main/release)
    Push bool
}

// Tasks returns the task graph for docker build+push
func (b *BuildAndPush) Tasks(s *sykli.Sykli) {
    if b.Dockerfile == "" {
        b.Dockerfile = "Dockerfile"
    }
    if b.Context == "" {
        b.Context = "."
    }

    // Build task
    buildCmd := fmt.Sprintf("docker build -t %s -f %s", b.Image, b.Dockerfile)
    for k, v := range b.BuildArgs {
        buildCmd += fmt.Sprintf(" --build-arg %s=%s", k, v)
    }
    buildCmd += " " + b.Context

    s.Task("docker:build").
        Container("docker:24").
        Run(buildCmd).
        When(b.Condition)

    // Push task (conditional)
    if b.Push {
        s.Task("docker:push").
            Container("docker:24").
            Run(fmt.Sprintf("docker push %s", b.Image)).
            DependsOn("docker:build").
            When(b.Condition)
    }
}
```

### Usage

```go
package main

import (
    "github.com/sykli-io/sykli-go"
    docker "github.com/sykli-io/sykli-docker"  // Versioned package
)

func main() {
    s := sykli.New()

    // Use the module
    docker.BuildAndPush{
        Image:     "myapp:" + sykli.GitSHA(),
        Condition: sykli.Branch("main").Or(sykli.Tag("v*")),
        Push:      true,
    }.Tasks(s)

    s.Run()
}
```

---

## Module vs Orb Comparison

```
┌─────────────────────────────────────────────────────────────────┐
│                    MODULES vs ORBS                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   CircleCI Orbs:                                                │
│   ├── YAML templates                                            │
│   ├── Published to CircleCI registry                            │
│   ├── @version pinning                                          │
│   ├── No type safety                                            │
│   ├── No IDE support                                            │
│   └── Can't unit test                                           │
│                                                                 │
│   Sykli Modules:                                                │
│   ├── Real code (Go/Elixir/Rust/TS)                             │
│   ├── Published to pkg.go.dev/Hex/crates.io/npm                 │
│   ├── Semantic versioning                                       │
│   ├── Full type safety                                          │
│   ├── Full IDE support (autocomplete, docs)                     │
│   └── Unit testable                                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Module Types

### 1. Task Modules

Provide common task patterns:

```go
// sykli-go-build - Go build patterns
go_build.Tasks{
    Packages: "./...",
    GOOS:     []string{"linux", "darwin", "windows"},
    GOARCH:   []string{"amd64", "arm64"},
}.Register(s)

// sykli-pytest - Python test patterns
pytest.Tasks{
    Paths:    []string{"tests/"},
    Parallel: true,
    Coverage: true,
}.Register(s)
```

### 2. Service Modules

Provide common service containers:

```go
// sykli-postgres - PostgreSQL service
s.Task("test").
    Services(postgres.Service{
        Version: "15",
        DB:      "testdb",
    }).
    Run("pytest tests/")
```

### 3. Target Modules

Provide pre-configured targets:

```go
// sykli-k8s-gcp - GCP-optimized K8s target
target := gcp.K8sTarget{
    Project:   "my-project",
    Zone:      "us-central1-a",
    NodePool:  "ci-pool",
    UseSpot:   true,
}

s.Target(target)
```

### 4. Workflow Modules

Complete CI/CD workflows:

```go
// sykli-release - Release workflow
release.Workflow{
    Changelog:   true,
    GitHubRelease: true,
    DockerPush:  true,
    HelmPublish: true,
}.Register(s)
```

---

## The Target Injection Pattern

Key insight: **Modules define WHAT, users provide WHERE**.

```go
// Module defines the tasks
docker.BuildAndPush{
    Image: "myapp:latest",
    // ...

    // User injects the target
    Target: myK8sTarget,

    // User injects the condition
    Condition: sykli.Branch("main"),
}
```

This separation enables:
- Same module, different environments (local vs CI)
- Same module, different conditions (branch vs tag)
- Testability (mock targets in tests)

---

## Module Discovery & Registry

### Package Manager Native

```bash
# Go
go get github.com/sykli-io/sykli-docker@v1.0.0

# Elixir
mix deps.get sykli_docker

# Rust
cargo add sykli-docker

# TypeScript
npm install @sykli/docker
```

### Sykli Registry (Future)

```bash
# Search for modules
$ sykli modules search docker

Found 12 modules:
  sykli/docker         Official Docker module          v2.1.0
  sykli/docker-compose Multi-container builds          v1.3.0
  myorg/docker-ecr     ECR-optimized Docker            v1.0.0
  ...

# Get info
$ sykli modules info sykli/docker

sykli/docker v2.1.0
───────────────────────────────────────
Official Docker build and push module

Tasks:
  docker:build    Build Docker image
  docker:push     Push to registry
  docker:scan     Scan for vulnerabilities

Languages: Go, Elixir, Rust, TypeScript
Downloads: 45,230
Stars: 234
```

---

## Module Development

### Creating a Module

```bash
$ sykli modules init mymodule

Created module structure:
  mymodule/
  ├── go/
  │   ├── mymodule.go
  │   ├── mymodule_test.go
  │   └── go.mod
  ├── elixir/
  │   ├── lib/mymodule.ex
  │   ├── test/mymodule_test.exs
  │   └── mix.exs
  └── README.md
```

### Testing a Module

```go
// mymodule_test.go
func TestBuildAndPush(t *testing.T) {
    s := sykli.NewTest()

    docker.BuildAndPush{
        Image: "test:latest",
    }.Tasks(s)

    // Verify tasks were created correctly
    assert.TaskExists(t, s, "docker:build")
    assert.TaskExists(t, s, "docker:push")
    assert.TaskDependsOn(t, s, "docker:push", "docker:build")
}
```

### Publishing a Module

```bash
# Go
$ cd go && go mod tidy && git tag v1.0.0 && git push --tags

# Elixir
$ cd elixir && mix hex.publish

# Rust
$ cd rust && cargo publish
```

---

## Official Modules (Roadmap)

| Module | Description | Priority |
|--------|-------------|----------|
| `sykli/docker` | Docker build, push, scan | P0 |
| `sykli/go` | Go build, test, lint | P0 |
| `sykli/node` | Node.js build, test, lint | P0 |
| `sykli/python` | Python test, lint, package | P1 |
| `sykli/rust` | Rust build, test, clippy | P1 |
| `sykli/helm` | Helm package, publish | P1 |
| `sykli/k8s-deploy` | K8s deployment patterns | P1 |
| `sykli/postgres` | PostgreSQL service | P1 |
| `sykli/redis` | Redis service | P1 |
| `sykli/release` | Release workflow | P2 |
| `sykli/notify` | Slack/Discord notifications | P2 |

---

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **Native packages (chosen)** | Type-safe, testable, IDE support | Multi-language effort |
| **YAML templates** | Single format | Not type-safe, fragile |
| **JSON schemas** | Language-agnostic | Verbose, no IDE support |
| **Plugin system** | Dynamic loading | Complexity, security |

---

## Success Criteria

1. At least 5 official modules published (docker, go, node, postgres, redis)
2. Modules installable via native package managers
3. Full autocomplete and documentation in IDEs
4. Modules are unit testable
5. Third-party modules can be published

---

## Future Work

- Multi-language module code generation (write once, generate for all)
- Module composition (modules that use other modules)
- Module marketplace with ratings and reviews
- Verified publisher badges
- Security scanning for modules