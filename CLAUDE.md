# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Sykli?

AI-native CI engine. Pipelines are written as real code (Go/Rust/TypeScript/Elixir/Python SDKs), emitted as JSON task graphs, and executed by an Elixir/BEAM engine. Every run produces structured context (FALSE Protocol occurrences) that AI assistants can read directly — no log parsing.

## Build & Test Commands

All core development happens in `core/`:

```bash
cd core
mix deps.get              # install dependencies (first time)
mix test                  # run all tests (~1101 tests)
mix test test/sykli/executor_test.exs           # single test file
mix test test/sykli/executor_test.exs:42        # single test at line
mix test --only integration                      # tagged tests
mix format                # format code
mix escript.build         # build the sykli binary → core/sykli
./sykli --help            # smoke test the binary
```

SDK conformance tests (validates SDK JSON output against expected cases):
```bash
tests/conformance/run.sh                    # all SDKs, all cases
tests/conformance/run.sh --sdk go           # single SDK
tests/conformance/run.sh case-name          # single case
```

Black-box tests (run against the built binary):
```bash
test/blackbox/run.sh              # all 84 cases, 7 categories
test/blackbox/run.sh --verbose    # show failure details
test/blackbox/run.sh --filter=POS # filter by category
```

Before every commit: `mix format && mix test && mix escript.build`

## Architecture

```
sykli.go ──emit──▶ JSON task graph (stdout) ──▶ Elixir engine ──▶ .sykli/ (AI context)
  SDK                                              │
                                          ┌────────┼────────┐
                                          ▼        ▼        ▼
                                       Target   Executor  Occurrence
                                    (where)    (how)     (what happened)
```

### OTP Supervision Tree

`Sykli.Application` starts (`:rest_for_one` strategy):
1. `Sykli.ULID` — monotonic ID generation
2. `Phoenix.PubSub` — occurrence broadcasting (`Sykli.PubSub`)
3. `Task.Supervisor` — isolated task execution (`Sykli.TaskSupervisor`)
4. `Sykli.RunRegistry` — tracking active runs
5. `Sykli.Executor.Server` — GenServer for stateful execution + occurrence emission

### Execution Flow

1. **Detector** (`detector.ex`) finds `sykli.*` file, runs it with `--emit` flag
2. **Graph** (`graph.ex`) parses JSON into Task structs, validates DAG (topological sort, cycle detection), expands matrix builds
3. **Executor** (`executor.ex`) runs tasks level-by-level in parallel, handles caching/retry/conditions/gates
4. **Target** executes commands — Local (Docker/Shell) or Kubernetes (Jobs)
5. **Occurrence** pipeline emits FALSE Protocol events, enriches terminal events with error/reasoning/history blocks, persists to `.sykli/`

### Key Modules

| Module | File | Role |
|--------|------|------|
| `CLI` | `cli.ex` | Command dispatch (17 commands) |
| `Graph` | `graph.ex` | JSON → Task DAG, validation, matrix expansion |
| `Graph.Task` | `graph.ex` + `graph/task/*.ex` | Task struct with semantic/ai_hooks/history fields |
| `Executor` | `executor.ex` | DAG execution with `Executor.Config` struct, AI hooks, concurrency limiting |
| `Executor.Server` | `executor/server.ex` | GenServer wrapper for run tracking + occurrence emission |
| `Target.Local` | `target/local.ex` | Local execution via Runtime (Docker or Shell) |
| `Target.K8s` | `target/k8s.ex` | Kubernetes Job execution |
| `Runtime.*` | `runtime/*.ex` | HOW commands execute — Shell, Docker, Podman (distinct from Target = WHERE) |
| `Occurrence` | `occurrence.ex` | FALSE Protocol event factory (12 types) |
| `Occurrence.PubSub` | `occurrence/pubsub.ex` | Phoenix.PubSub broadcast on `sykli:occurrences:*` topics |
| `Occurrence.Enrichment` | `occurrence/enrichment.ex` | Terminal event enrichment + JSON/ETF persistence |
| `Occurrence.Store` | `occurrence/store.ex` | Three-tier storage: ETS (hot) → ETF (warm) → JSON (cold) |
| `Context` | `context.ex` | Generates `.sykli/context.json` and `test-map.json` |
| `Explain` | `explain.ex` | Pipeline structure, levels, critical path |
| `Fix` | `fix.ex` + `fix/output.ex` | Failure analysis with source context and git diff |
| `Plan` | `plan.ex` | Dry-run with git diff analysis |
| `Query` | `query.ex` + `query/*.ex` | Pattern-matched natural language queries (no LLM) |
| `MCP.Server` | `mcp/server.ex` | MCP server (stdio, 5 tools) |
| `Delta` | `delta.ex` | Git-change-based task selection |
| `Services.*` | `services/*.ex` | CacheService, RetryService, ConditionService, GateService, ProgressTracker, etc. |
| `Cache` | `cache.ex` + `cache/*.ex` | Content-addressed caching (SHA256), tiered repository (local + S3) |
| `SCM` | `scm.ex` + `scm/*.ex` | Multi-provider commit status (GitHub/GitLab/Bitbucket) |
| `Telemetry` | `telemetry.ex` | `:telemetry` spans/events for tasks, cache, runs |
| `HTTP` | `http.ex` | Shared TLS verification opts for `:httpc` callers |
| `Error` | `error.ex` | Structured error types with formatter |
| `Attestation` | `attestation.ex` + `attestation/*.ex` | SLSA v1.0 provenance generation, DSSE envelope, signing |

### TaskResult Status Values

- `:passed` — task ran and succeeded
- `:failed` — task's command returned non-zero exit code (content failure — code is broken)
- `:errored` — infrastructure failure (process crash, timeout, OIDC, missing secrets)
- `:cached` — cache hit, skipped execution
- `:skipped` — condition not met
- `:blocked` — dependency failed

When checking for failures, always match both: `status in [:failed, :errored]`. The distinction matters for AI analysis — `:failed` gets causality analysis, `:errored` gets infrastructure diagnostics.

### Task Schema (Three Layers)

Tasks carry metadata at three levels, all implemented in all SDKs:

- **Static** (user declares): `covers`, `intent`, `criticality` — semantic metadata
- **Behavioral** (user configures): `on_fail` (analyze/retry/skip), `select` (smart/always/manual) — AI hooks
- **Learned** (Sykli populates): flakiness, avg duration, failure patterns — history hints

### FALSE Protocol Occurrences

All internal events are `%Sykli.Occurrence{}` structs broadcast via Phoenix.PubSub. Types:

`ci.run.started`, `ci.run.passed`, `ci.run.failed`, `ci.task.started`, `ci.task.completed`, `ci.task.cached`, `ci.task.skipped`, `ci.task.retrying`, `ci.task.output`, `ci.cache.miss`, `ci.gate.waiting`, `ci.gate.resolved`

Terminal events get enriched with `error`, `reasoning`, `history` blocks by `Occurrence.Enrichment`.

Occurrence context carries `trace_id`, `span_id`, and `chain_id` (for correlating retry chains). The `source` field is configurable via `SYKLI_SOURCE_URI` env var or `Application.get_env(:sykli, :source)`, defaulting to `"sykli"`.

### .sykli/ Directory (AI's Memory)

```
.sykli/
├── occurrence.json          # latest run (FALSE Protocol, always written)
├── attestation.json         # DSSE envelope with SLSA v1.0 provenance (per-run)
├── attestations/            # per-task DSSE envelopes (for artifact registries)
├── occurrences_json/        # per-run JSON archive (last 20)
├── occurrences/             # ETF archive (last 50, fast BEAM reload)
├── context.json             # pipeline structure + health (via `sykli context`)
├── test-map.json            # file → tasks mapping (via `sykli context`)
└── runs/                    # run history manifests
```

## SDKs

Five SDKs in `sdk/` — Go, Rust, TypeScript, Elixir, Python. All support the full API including semantic metadata, containers, mounts, services, K8s options, caches, secrets, gates, matrix, capabilities.

SDK detection order: `.go` → `.rs` → `.exs` → `.ts` → `.py`

SDKs are run with `--emit`, must output valid JSON to stdout. When changing task schema fields, update all five SDKs and their conformance test cases.

The project dogfoods itself via `sykli.exs` (root-level pipeline) and `.github/workflows/sykli-ci.yml`.

## CLI Commands

`run`, `validate`, `init`, `explain`, `fix`, `plan`, `context`, `query`, `graph`, `report`, `history`, `verify`, `delta`, `watch`, `daemon`, `mcp`, `cache`

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `SYKLI_SOURCE_URI` | Override occurrence `source` field (default: `"sykli"`) |
| `SYKLI_CACHE_S3_BUCKET` | Enable S3 cache tier (with `_REGION`, `_ENDPOINT`, `_ACCESS_KEY`, `_SECRET_KEY`) |
| `SYKLI_LABELS` | Node profile labels for mesh placement |
| `SYKLI_COOKIE` | Erlang distribution cookie for daemon/mesh mode |
| `SYKLI_K8S_NAMESPACE` | K8s target namespace (default: `"sykli"`) |
| `SYKLI_SIGNING_KEY` | HMAC-SHA256 key for signing DSSE attestation envelopes |
| `GITHUB_TOKEN` / `GITLAB_TOKEN` / `BITBUCKET_TOKEN` | SCM commit status integration |

## Testing Patterns

- Tests exclude `:integration` tag by default — run with `mix test --only integration`
- `@tag :docker` marks tests requiring Docker daemon (1 test, skipped when unavailable)
- Some tests use `async: false` due to GenServer state (coordinator, events, delta, watch)
- No global test helpers — each test file is self-contained

## Patterns & Conventions

- **Behaviours over protocols** for targets/runtimes — `Sykli.Target.Behaviour`, `Sykli.Runtime.Behaviour`
- **`run_id` is threaded explicitly** through executor functions — never use Process dictionary
- **Occurrence emission** uses `maybe_emit_*` helpers that pattern-match `nil` run_id to no-op
- **Services** are stateless modules in `services/` — no GenServers, just functions
- **Structured errors** via `Sykli.Error` — never bare strings. Use `Sykli.Error.task_failed/5`, etc.
- **JSON output** — most commands support `--json` for machine-readable output
- **Executor.Config** — executor options flow through `%Executor.Config{}` struct (target, timeout, run_id, max_parallel, continue_on_failure)
- **HTTP with TLS** — all `:httpc` callers use `Sykli.HTTP.ssl_opts/1` for `verify_peer` + hostname checking
- **Cache backend selection** — `Sykli.Cache.repo/0` dynamically selects FileRepository or TieredRepository (L1 local + L2 S3) based on env vars
- **Secret masking** — `SecretMasker.mask_deep/2` applied to occurrence data before persistence and webhook delivery
- **Path containment** — file reads and Docker mounts must use `String.starts_with?(path, base <> "/")` to prevent path traversal (trailing slash prevents prefix tricks)
- **TLS everywhere** — all `:httpc` calls must include `Sykli.HTTP.ssl_opts/1` (OIDC, S3, SCM, webhooks)
- **Elixir heredoc gotcha** — `"""` embeds literal newlines that break JSON. Use `~s()` for single-line JSON in test fixtures
- **~s() with parens gotcha** — `~s()` uses `()` as delimiters, so `~s(matches(x, "y"))` breaks. Use `~s[]` or `~S||` instead

## Git Workflow

- Never push directly to main — use feature branches + PRs
- Branch naming: `feature/<short-description>`
- Push with `-u`, then `gh pr create` targeting main

## Known Issues

- `--timeout` flag doesn't enforce timeouts on local target (tasks run to completion)
- 1 test requires Docker daemon running (skipped when unavailable)
- See `docs/deep-dive-findings.md` for 37 tracked issues across security/reliability/architecture/test coverage
