# sykli

Execution contracts for agent work.

Sykli turns build, test, deploy, review, and approval work into typed,
versioned, verifiable execution graphs.

Agents can plan, generate, review, and adapt, but their work still needs
boundaries: what is being run, what it depends on, what environment it needs,
what success means, and what evidence another tool can trust afterward.

Sykli is that boundary.

You define the graph in a real programming language: Go, Rust, TypeScript,
Elixir, or Python. Sykli emits a canonical JSON contract, validates it against
versioned schemas, executes it on BEAM, and writes structured runtime evidence
to `.sykli/`.

The goal is not to make agentic work perfectly deterministic. The goal is to
make the contract around it deterministic enough to inspect, verify, replay,
and hand to other tools.

Sykli makes agent work visible before it runs and trustworthy after it
finishes.

```go
package main

import sykli "github.com/false-systems/sykli/sdk/go"

func main() {
    s := sykli.New()

    s.Task("test").
        Run("go test ./...").
        TaskType(sykli.TaskTypeTest).
        Inputs("**/*.go").
        SuccessCriteria(sykli.ExitCode(0))

    s.Task("build").
        Run("go build -o app").
        TaskType(sykli.TaskTypeBuild).
        After("test").
        Output("binary", "app").
        SuccessCriteria(
            sykli.ExitCode(0),
            sykli.FileExists("app"),
        )

    s.Review("review:api_breakage").
        Primitive("api_breakage").
        Agent("local").
        Diff("main...HEAD").
        Context("README.md", "docs/sdk-schema.md").
        After("test")

    s.Emit()
}
```

```text
sykli · pipeline.go                                local · 0.7.0

  ●  test     go test ./...                        108ms
  ●  build    go build -o app                      612ms
  ○  review:api_breakage   api_breakage            planned

  ─  2 passed · 1 review planned                   720ms
```

Task nodes execute deterministic work such as build and test commands. Review
nodes model evaluation work as graph nodes: primitive, agent identifier,
context files, dependencies, and `deterministic: false` by default. Review
nodes are not shell tasks.

## When It Fails, Agents Read Facts — Not Logs

Every terminal result carries a typed classification. An agent consuming
`sykli run --json` (or `sykli report --json`, or the MCP server) sees this for
a task whose command succeeded but whose declared `success_criteria` did not:

```json
{
  "name": "test",
  "status": "failed",
  "failure_semantics": {
    "class": "criteria_failure",
    "retryable": false,
    "source": "criteria",
    "reason": "success_criteria_failed",
    "message": "task 'test' failed success_criteria",
    "details": {
      "code": "success_criteria_failed",
      "task": "test",
      "step": "run"
    }
  },
  "agent_hints": {
    "retry_may_help": false,
    "inspect_target": false,
    "inspect_contract": true,
    "inspect_dependencies": false,
    "requires_human_decision": false,
    "unknown_failure_class": false
  }
}
```

The agent branches on `class` — `runtime_failure`, `criteria_failure`,
`timeout`, `dependency_failure`, `policy_block`, `missing_evidence`, and
friends — instead of regexing log text. `agent_hints` says which follow-up
paths are semantically valid; it is deliberately not a diagnosis engine.
Results also carry a `contract_slice`: the declared task semantics that
governed the outcome, so a tool can see *which contract* failed without
re-parsing the pipeline.

`sykli fix` renders the same facts with source context for AI-assisted repair,
and `sykli mcp` serves them to agents directly. See
[`docs/failure-semantics.md`](docs/failure-semantics.md) and
[`docs/agent-readable-failure-output.md`](docs/agent-readable-failure-output.md).

## What Sykli Gives You

- Typed SDKs instead of YAML as the source of truth.
- Canonical JSON contract emitted by every SDK.
- Explicit wire-format versions and schema validation.
- DAG validation, dependency scheduling, supervision, retries, and caching.
- Structured `task_type`, `success_criteria`, and `evidence_required` fields.
- Task, review, gate, artifact, resource, container, and cache primitives.
- `.sykli/` evidence output for agents, MCP tools, CI, and downstream systems.
- Portable execution across local shell, Docker, Podman, Kubernetes, and BEAM
  mesh, depending on feature maturity.

## Sykli Is Not CI

Sykli is not a CI system in the narrow sense. It is a compiler and runtime for
execution graphs.

Builds, tests, deployments, release checks, reviews, security analysis,
approvals, and agent-driven reasoning can all be represented as nodes in the
same graph. CI is the first obvious use case because CI already has the right
primitives: tasks, dependencies, inputs, outputs, and execution order.

The shift is that the pipeline is no longer hidden inside vendor YAML and shell
scripts. It becomes a typed program that emits an explicit execution contract.

## Why YAML Is Not Enough

YAML pipelines fail at four things that get worse as the graph grows:

- **No types.** Typos and wrong parameter shapes usually fail at runtime.
- **Poor reuse.** Anchors and includes are not real composition.
- **Hidden logic.** Behavior is split across conditionals, matrices, env files,
  shell scripts, and runner semantics.
- **Vendor lock-in.** The pipeline belongs to the CI vendor instead of the
  project.

A pipeline is a program. Agent work needs a contract.

## How It Works

1. **Author.** Write the graph in Go, Rust, TypeScript, Elixir, or Python.
2. **Emit.** The SDK emits canonical JSON governed by
   [`schemas/sykli-pipeline.schema.json`](schemas/sykli-pipeline.schema.json).
3. **Validate.** The engine rejects malformed contracts, unsupported versions,
   cycles, invalid dependencies, and incompatible fields.
4. **Execute.** The BEAM engine schedules graph levels, supervises tasks,
   applies runtime selection, and records structured results.
5. **Observe.** Terminal events become FALSE Protocol occurrences and run
   artifacts under `.sykli/`.

The same contract can be read by the engine, agents, MCP tools, CI wrappers,
auditors, and release tooling without scraping logs.

## Wire Format

Wire-format versions are explicit, not advisory:

| Version | Meaning |
|---------|---------|
| `"1"` | Baseline task graph |
| `"2"` | Resources, containers, mounts, and cache metadata |
| `"3"` | Agent-native semantic fields such as `task_type` and `success_criteria` |
| `"4"` | Required evidence references via `evidence_required` |

SDKs auto-detect the minimum version from the features used. The engine rejects
missing, empty, malformed, and unsupported versions. `task_type` and
`success_criteria` require version `"3"` or newer; `evidence_required` requires
version `"4"`. See [`docs/sdk-schema.md`](docs/sdk-schema.md) for the field
contract.

## Why BEAM Matters

Sykli uses BEAM because execution graphs are naturally concurrent, supervised,
distributed, and failure-heavy.

BEAM gives the engine:

- Lightweight processes for graph nodes, watchers, services, and coordinators.
- Supervision trees for structured failures instead of process-wide crashes.
- Message passing instead of shared mutable state.
- Distribution primitives for mesh execution.
- Fault isolation between tasks, runtimes, agents, and background services.
- Long-running daemon support for local, remote, and CI-triggered work.

BEAM is an architectural choice: the runtime has the same shape as the problem.

## Distributed, With Deterministic Boundaries

Sykli can run locally, in containers, on Kubernetes, or across a BEAM mesh.
Local execution and container execution are stable. Mesh execution and the
Kubernetes target are beta.

- **Mesh execution.** `sykli daemon start` keeps a BEAM node running.
  Capability labels such as `gpu` can be used for placement, and `--mesh`
  opts into distributed execution.
- **Deterministic boundaries.** Time, randomness, and transport are kept behind
  controllable boundaries where the engine owns them. The repo includes a
  `NoWallClock` Credo check to keep raw wall-clock and random calls out of
  deterministic engine paths.
- **Retry semantics.** Tasks run under supervision. Failures become structured
  task results, and retry/fail/skip behavior follows the task contract.

This is not a claim that all distributed or agent work becomes deterministic.
The contract boundary is what Sykli makes inspectable.

## Agentic Review As Code

Review nodes are experimental.

A review node is a structured review step in the graph. It is not a shell task,
and it does not call Codex, Claude, or other LLM providers directly. It gives
future agent and tool runners a controlled, inspectable shape for review work.

Builders exist in all five SDKs and are covered by cross-SDK conformance. Review
nodes have a separate schema surface from task nodes; the schema rejects task
execution fields such as `command`, `outputs`, `services`, `mounts`, `k8s`,
`retry`, `timeout`, `task_type`, `success_criteria`, and `evidence_required` on
review nodes.

```go
s.Review("review:api_breakage").
    Primitive("api_breakage").
    Agent("local").
    Diff("main...HEAD").
    Context("README.md", "docs/sdk-schema.md").
    After("test")
```

Current review support includes graph modeling, schema validation, SDK builders,
runtime dispatch for deterministic primitives, and a structured `review_result`
shape. The default `api_breakage` primitive boundary returns an explicit
unsupported result until a real adapter is configured. LLM provider calls,
prompt templates, and broader review primitive implementations are not bundled.

Planned primitive areas include security boundaries, API breakage, behavior
regression, test coverage gaps, and architecture boundary checks.

## Use Cases

| Use case | What Sykli gives you |
|----------|----------------------|
| Agentic workflows | Agents are executors; the graph defines what runs, what it depends on, and what evidence it produces |
| PR reviews | Experimental review nodes with constrained context and explicit primitive semantics |
| Release checks | SLSA v1.0 provenance attestations and structured run evidence |
| Security validation | Secret-scoped tasks, OIDC token exchange, and webhook hardening in the core engine |
| Infrastructure validation | The same graph can target local execution, containers, Kubernetes, or a BEAM mesh |
| CI pipelines | The CI graph as code, with cache keys, dependency-level parallelism, and structured results |

## Design Principles

- **Real languages, not DSLs.** Pipelines are Go, Rust, TypeScript, Elixir, or
  Python programs.
- **Explicit dependencies.** The DAG is the source of truth.
- **Typed APIs.** SDKs are checked by their host language and cross-SDK
  conformance tests.
- **Portable execution.** One graph can run locally, in containers, on
  Kubernetes, or across a mesh.
- **Local-first.** Network features are additive.
- **No YAML-first.** YAML can be a projection; it is not the source of truth.
- **Agents are executors, not magic.** A review primitive is a constrained graph
  node.
- **Determinism is a boundary.** Sykli constrains nondeterminism with typed
  contracts and structured evidence.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/false-systems/sykli/main/install.sh | bash
```

Or [download a binary](https://github.com/false-systems/sykli/releases/latest) for
macOS or Linux.

<details>
<summary>Build from source</summary>

```bash
git clone https://github.com/false-systems/sykli.git
cd sykli/core
mix deps.get
mix escript.build
sudo mv sykli /usr/local/bin/
```

Requires Elixir 1.14+.
</details>

## Pick Your SDK

| Language | Install | Default file |
|----------|---------|--------------|
| Go | `go get github.com/false-systems/sykli/sdk/go@latest` | `sykli.go` |
| Rust | `sykli = "0.7.0"` in `Cargo.toml` | `sykli.rs` |
| TypeScript | `npm install sykli@0.7.0` | `sykli.ts` |
| Elixir | `{:sykli_sdk, "~> 0.7.0"}` in `mix.exs` | `sykli.exs` |
| Python | `pip install sykli==0.7.0` | `sykli.py` |

All SDKs emit the same canonical contract shape.

## Capabilities

```go
// Content-addressed cache
s.Task("test").Run("go test ./...").Inputs("**/*.go", "go.mod")

// Containers and cache mounts
s.Task("build").
    Container("golang:1.22").
    Mount(s.Dir("."), "/src").
    MountCache(s.Cache("go-mod"), "/go/pkg/mod").
    Workdir("/src").
    Run("go build -o app")

// Matrix expansion
s.Task("test").Run("go test ./...").Matrix("go", "1.21", "1.22", "1.23")

// Gates
s.Gate("approve-deploy").Message("Deploy?").Strategy("prompt")
s.Task("deploy").Run("./deploy.sh").After("approve-deploy")

// Artifact passing
s.Task("build").Run("go build -o /out/app").Output("binary", "/out/app")
s.Task("deploy").InputFrom("build", "binary", "/app/bin").Run("./deploy.sh /app/bin")

// Capability-based placement
s.Task("train").Requires("gpu").Run("python train.py")

// Conditional execution and secrets
s.Task("deploy").Run("./deploy.sh").When("branch == 'main'").Secret("DEPLOY_TOKEN")
```

These examples use existing Go SDK APIs covered by SDK tests and conformance
fixtures.

## CLI

```bash
sykli                     # run pipeline in the current project
sykli run                 # explicit run command
sykli --filter=test       # run matching tasks
sykli --timeout=5m        # per-task timeout
sykli --mesh              # opt into mesh execution
sykli --target=k8s        # run through the Kubernetes target
sykli --runtime=podman    # select runtime

sykli init                # generate SDK file
sykli validate            # validate graph without running
sykli plan                # dry-run execution plan
sykli delta               # run tasks affected by git changes
sykli watch               # re-run on file changes
sykli explain             # show last run as an AI-readable report
sykli fix                 # failure analysis with source context
sykli context             # write .sykli/context.json
sykli query               # query pipeline, history, and health data
sykli graph               # Mermaid or DOT graph
sykli verify              # cross-platform verification via mesh
sykli history             # recent runs
sykli report              # last run summary

sykli work list           # local work items
sykli run --work <id>     # associate a run with a work item
sykli work runs <id>      # runs associated with a work item
sykli gates list          # local gate decisions
sykli gate approve <id> --reason "Reviewed"
sykli cache stats         # cache statistics
sykli daemon start        # start a mesh daemon
sykli mcp                 # MCP server for AI assistants
```

Run `sykli --help` or a subcommand's `--help` for flags and JSON output modes.

## Runtimes

Sykli separates targets, where a task runs, from runtimes, how a command
executes.

Supported runtimes:

- `Docker`
- `Podman` rootless
- `Shell` with no container isolation
- `Fake` for deterministic tests

```bash
SYKLI_RUNTIME=podman sykli
sykli --runtime=podman
sykli -r podman
```

Selection priority and runtime extension notes are in
[`docs/runtimes.md`](docs/runtimes.md).

## `.sykli/` Evidence

```text
.sykli/
├── occurrence.json       # latest terminal FALSE Protocol occurrence
├── occurrences_json/     # archived JSON occurrences
├── occurrences/          # archived ETF occurrences
├── attestation.json      # run-level DSSE/SLSA provenance envelope
├── attestations/         # per-task DSSE envelopes when outputs are attested
├── context.json          # pipeline and health context from `sykli context`
├── runs/                 # run history manifests
├── work/items/           # local work item state
└── gates/                # local gate decision state
```

This is the local evidence plane. Agents and downstream tools read structured
data instead of scraping terminal output.

The detailed on-disk schema is documented in
[`docs/false-protocol-schema.md`](docs/false-protocol-schema.md).

## Project Status

| Component | Status |
|-----------|--------|
| Core engine, all 5 SDKs, local execution, Docker/Podman/Shell/Fake runtimes, FALSE Protocol output, canonical schema, opt-in GitHub-native receiver | **Stable** |
| Mesh distribution, Kubernetes target, gates, SLSA attestations, remote cache via S3, review-node graph support, `task_type` / `success_criteria` v3 fields, `evidence_required` v4 fields | **Beta** |
| Review primitive adapters, broader review primitive implementations, multi-agent execution, LLM/provider review runners | **In development** |

The status table is part of the contract: beta and in-development features are
usable surfaces, not production-readiness claims.

## Roadmap

- Review primitive adapters for API, security, coverage, behavior, and
  architecture checks.
- Structured review outputs with primitive-specific schemas.
- Multi-agent execution for nodes that can be fulfilled by several executors.
- Continued GitHub-native and self-hosted coordinator work.
- Expanded public FALSE Protocol compatibility for downstream evidence
  consumers.

## Contributing

MIT licensed. Start with [CONTRIBUTING.md](CONTRIBUTING.md) — it covers the
build, the test tiers, and the project rules that are enforced by tests.

```bash
cd core
mix test
mix credo
mix escript.build

cd ..
test/blackbox/run.sh --verbose
tests/conformance/run.sh
```

See [CLAUDE.md](CLAUDE.md) for architecture notes, conventions, and design
rationale.

---

<div align="center">

**sykli** (Finnish: *cycle*) — built in Berlin, powered by BEAM.

**[Install](#install)** · **[Schema](schemas/sykli-pipeline.schema.json)** · **[Contract](docs/sdk-schema.md)** · **[Issues](https://github.com/false-systems/sykli/issues)**

</div>
