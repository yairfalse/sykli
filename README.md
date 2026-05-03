# sykli

**Execution graphs as code.**

sykli lets you define tasks, dependencies, inputs, outputs, and execution logic in a real programming language — Go, Rust, TypeScript, Elixir, or Python — and emit an explicit execution plan that any runner can execute.

```go
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()

    s.Task("test").
        Run("go test ./...").
        Inputs("**/*.go")

    s.Task("build").
        Run("go build -o app").
        After("test").
        Outputs("app")

    s.Review("review:api-breakage").
        Primitive("api-breakage").
        Agent("local").
        Diff("main...HEAD").
        Context("README.md", "docs/architecture.md").
        After("test").
        Outputs("reviews/api-breakage.json")

    s.Emit()
}
```

```
sykli · pipeline.go                                local · 0.6.0

  ●  test     go test ./...                        108ms
  ●  build    go build -o app                      612ms
  ○  review:api-breakage   api-breakage            planned

  ─  2 passed · 1 review planned                   720ms
```

The `review:api-breakage` node is not a shell task. It is a structured review node in the graph: primitive, agent identifier, diff input, context files, dependencies, outputs, and `deterministic: false`.

---

## sykli is not CI

sykli is not a CI system in the narrow sense.

It is a compiler for execution graphs. Builds, tests, deployments, reviews, release checks, security analysis, and agent-driven reasoning can all be represented as nodes in the same graph. CI is simply the first obvious use case because CI already has the right primitives — tasks, dependencies, inputs, outputs, execution order.

The important shift is that the pipeline is no longer hidden inside YAML and shell scripts. It becomes a real program that emits an explicit, inspectable execution plan.

## Why YAML is not enough

YAML pipelines fail at four things that get worse over time:

- **No types.** A typo in a job name or a wrong parameter type fails at runtime, often inside the cloud provider's job log. There is no compiler.
- **Poor reuse.** Anchors and includes paper over the gap. Real composition — pass values, build helpers, derive task lists from data — is impossible without escape-hatch shell.
- **Hidden logic.** The actual decision tree is split across `if:` conditionals, `needs:` graphs, matrix expansions, environment files, and the runner's behavior. Reading what will run requires running it.
- **Vendor lock-in.** GitHub Actions YAML doesn't run on GitLab, doesn't run on CircleCI, doesn't run on your laptop. The pipeline is property of the vendor, not the project.

A pipeline is a program. It deserves a programming language.

## How it works

```
sdk file (Go/Rust/TS/Elixir/Python)
   │
   │  --emit
   ▼
JSON task graph (stdout)
   │
   ▼
sykli engine: validate DAG → schedule levels → execute → observe
   │
   ▼
.sykli/ — structured occurrences, attestations, run history
```

1. **Define.** Write your graph in a real language. Use variables, functions, types.
2. **Emit.** sykli runs your SDK file with `--emit` and reads the resulting JSON.
3. **Execute.** The engine validates the DAG (cycle detection, schema, capability resolution), schedules tasks level-by-level in parallel, applies caching and retries.
4. **Observe.** Every event becomes a [FALSE Protocol](https://github.com/false-systems) occurrence written to `.sykli/`. AI agents and downstream tools read structured data, not log scrolls.

The engine runs on the BEAM VM. Same code on your laptop, in Docker, on Kubernetes, or across a mesh of nodes.

## Agentic review as code

SYKLI Reviews are experimental. A review node represents a structured review step in the execution graph; it does not yet run Codex, Claude, or any other provider directly. It models the review step so future runners can execute agents in a controlled, inspectable way.

The builder API is currently available in the Go SDK only. Rust, TypeScript, Elixir, and Python SDK builders still need parity work; until then, review nodes are an experimental Go-first graph feature.

Agentic workflows need primitives, not prompts. Asking an LLM to "review this PR" is too underspecified to be repeatable. Defining a review node with constrained inputs, expected outputs, and explicit rules is.

```go
s.Review("review:api-breakage").
    Primitive("api-breakage").
    Agent("local").
    Diff("main...HEAD").
    Context("README.md", "docs/architecture.md").
    After("test").
    Outputs("reviews/api-breakage.json")
```

A review primitive is a node with:

- **Constrained inputs.** A diff range, a directory, a manifest. Not "the whole repo, figure it out."
- **Expected outputs.** A structured JSON report at a known path. Not freeform commentary.
- **Explicit rules.** What counts as an api breakage, what counts as a coverage gap, what counts as an architecture-boundary violation.

Task nodes model deterministic work such as build and test commands. Review nodes model non-deterministic evaluation work such as agent review; they are `deterministic: false` by default.

Agents — local tools, hosted models, or deterministic linters — are executors inside the graph. Different runtimes can fulfill the same primitive. The graph is the contract; the executor is an implementation detail.

Planned primitives: `security-boundaries`, `api-breakage`, `behavior-regression`, `test-coverage-gap`, `architecture-boundary`. Provider calls, prompt templates, and review-result occurrences are future work.

## Use cases

| Use case | What sykli gives you |
|---|---|
| **CI pipelines** | The whole CI graph as code, content-addressed cache, parallel-by-dependency-level execution, deterministic replay |
| **PR reviews** | Reviews as graph nodes — agents and linters fulfill the same node contract |
| **Release checks** | SLSA v1.0 provenance attestations per task, signed by the engine, verifiable downstream |
| **Security validation** | Secret-scoped tasks, OIDC token exchange to cloud providers, SSRF-guarded webhooks |
| **Infrastructure validation** | Same task graph against `local`, `k8s`, or a self-hosted mesh of nodes |
| **Agentic workflows** | Agents are executors; the graph defines what runs, what it depends on, and what it outputs |

## Design principles

- **Real languages, not DSLs.** Pipelines are Go / Rust / TypeScript / Elixir / Python programs.
- **Explicit dependencies.** No implicit ordering, no hidden state. The DAG is the source of truth.
- **Typed APIs.** Each SDK is type-checked by its host language; cross-SDK behavior is enforced by a conformance suite.
- **Portable execution.** Same graph on a laptop, in Docker, on Kubernetes, or across a mesh.
- **Local-first.** The engine runs on hardware you control. Network features are additive, never required.
- **No YAML-first.** YAML is a *projection* of the graph for tools that need it, never the source of truth.
- **Agents are executors, not magic.** A review primitive is a node with constrained inputs and expected outputs. Whatever fulfills the contract — agent, linter, classifier — is interchangeable.
- **Determinism is testable.** Time, randomness, and clock are routed through transport APIs; runs replay byte-identically given a seed.

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

### Pick your SDK

| Language | Install | File |
|----------|---------|------|
| **Go** | `go get github.com/yairfalse/sykli/sdk/go@latest` | `sykli.go` |
| **Rust** | `sykli = "0.6"` in Cargo.toml | `sykli.rs` |
| **TypeScript** | `npm install sykli` | `sykli.ts` |
| **Elixir** | `{:sykli_sdk, "~> 0.6.0"}` in mix.exs | `sykli.exs` |
| **Python** | `pip install sykli` | `sykli.py` |

All SDKs share the same API surface. The file lives at the project root.

---

## Capabilities

```go
// Content-addressed cache
s.Task("test").Run("go test ./...").Inputs("**/*.go", "go.mod")

// Containers + cache mounts
s.Task("build").
    Container("golang:1.22").
    Mount(s.Dir("."), "/src").
    MountCache(s.Cache("go-mod"), "/go/pkg/mod").
    Workdir("/src").
    Run("go build -o app")

// Matrix expansion
s.Task("test").Run("go test ./...").Matrix("go", "1.21", "1.22", "1.23")

// Gates (approval points)
s.Gate("approve-deploy").Message("Deploy?").Strategy("prompt")
s.Task("deploy").Run("./deploy.sh").After("approve-deploy")

// Artifact passing between tasks
build := s.Task("build").Run("go build -o /out/app").Output("binary", "/out/app")
s.Task("deploy").InputFrom(build, "binary", "/app/bin").Run("./deploy.sh /app/bin")

// Capability-based placement
s.Task("train").Requires("gpu").Run("python train.py")

// Conditional execution
s.Task("deploy").Run("./deploy.sh").When("branch == 'main'").Secret("DEPLOY_TOKEN")
```

---

## CLI

```bash
sykli                     # run pipeline
sykli --filter=test       # run matching tasks
sykli --timeout=5m        # per-task timeout
sykli --mesh              # distribute across mesh
sykli --target=k8s        # run on Kubernetes
sykli --runtime=podman    # pick a container runtime

sykli init                # generate SDK file (auto-detects language)
sykli validate            # check graph without running
sykli plan                # dry-run, git-diff-driven task selection
sykli delta               # only tasks affected by git changes
sykli watch               # re-run on file changes
sykli explain             # show last run as AI-readable report
sykli fix                 # AI-readable failure analysis with source context
sykli context             # generate AI context file (.sykli/context.json)
sykli query               # query pipeline, history, and health data
sykli graph               # mermaid / DOT diagram of the DAG
sykli verify              # cross-platform verification via mesh
sykli history             # recent runs
sykli report              # show last run summary with task results
sykli cache stats         # cache hit rates
sykli daemon start        # start a mesh node on this host
sykli mcp                 # MCP server (Claude Code, Cursor, Copilot)
```

---

## Runtimes

`Docker`, `Podman` (rootless), `Shell` (no isolation), `Fake` (deterministic, used for tests). Auto-detect picks the first available; override per invocation:

```bash
SYKLI_RUNTIME=podman sykli
sykli --runtime=podman
```

Selection priority and how to add a new runtime: [docs/runtimes.md](docs/runtimes.md).

---

## .sykli/ — what lands on disk

```
.sykli/
├── occurrence.json       # latest run, FALSE Protocol structured event
├── attestation.json      # DSSE envelope with SLSA v1.0 provenance (per-run)
├── attestations/         # per-task DSSE envelopes (for artifact registries)
├── occurrences_json/     # per-run JSON archive (last 20)
├── context.json          # pipeline structure + health (via `sykli context`)
└── runs/                 # run history manifests
```

This is the layer agents and downstream tools read. No log parsing, no regex, no scraping the runner UI.

---

## Project status

| Component | Status |
|-----------|--------|
| Core engine, Go / Rust / TS / Elixir SDKs, local execution, containers, FALSE Protocol output | **Stable** |
| Python SDK, mesh distribution, K8s target, gates, SLSA attestations, remote cache (S3) | **Beta** |
| GitHub-native receiver (App + webhook + Checks API), review primitives, multi-agent execution | **In development** |

---

## Roadmap

- **Review primitives** — `review/security`, `review/api-breakage`, `review/observability-regression`, `review/test-coverage-gap`, `review/architecture-boundary` as first-class graph nodes
- **Structured review outputs** — typed JSON schema per primitive, consumable by other graph nodes
- **Multi-agent execution** — multiple executors fulfilling the same primitive, with disagreement surfaced as graph state
- **GitHub-native integration** — App + webhook receiver running on the user's mesh, replacing the in-Actions integration
- **FALSE Protocol output compatibility** — already the internal event model; expanding the public schema for downstream consumers

---

## Contributing

MIT licensed.

```bash
cd core
mix test                  # unit + integration tests
mix credo                 # lint, includes the NoWallClock check
mix escript.build         # build the binary

test/blackbox/run.sh      # black-box suite against the built binary
tests/conformance/run.sh  # cross-SDK JSON-output conformance
```

See [CLAUDE.md](CLAUDE.md) for architecture notes, conventions, and the design rationale behind the engine.

---

<div align="center">

**sykli** (Finnish: *cycle*) — built in Berlin, powered by BEAM.

**[Install](#install)** · **[ADRs](docs/adr/)** · **[Issues](https://github.com/yairfalse/sykli/issues)**

</div>
