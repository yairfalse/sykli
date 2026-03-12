# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Sykli?

AI-native CI engine. Pipelines are written as real code (Go/Rust/TypeScript/Elixir/Python SDKs), emitted as JSON task graphs, and executed by an Elixir/BEAM engine. Every run produces structured context (FALSE Protocol occurrences) that AI assistants can read directly — no log parsing.

## Build & Test Commands

All core development happens in `core/`:

```bash
cd core
mix deps.get              # install dependencies (first time)
mix test                  # run all tests (~1026 tests)
mix test test/sykli/executor_test.exs           # single test file
mix test test/sykli/executor_test.exs:42        # single test at line
mix test --only integration                      # tagged tests
mix format                # format code
mix escript.build         # build the sykli binary → core/sykli
./sykli --help            # smoke test the binary
```

Black-box tests (run against the built binary):
```bash
test/blackbox/run.sh              # all 64 cases, 7 categories
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
| `Target.Local` | `target/local.ex` | Local execution via Runtime (Docker or Shell) |
| `Target.K8s` | `target/k8s.ex` | Kubernetes Job execution |
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

### Task Schema (Three Layers)

Tasks carry metadata at three levels, all implemented in all SDKs:

- **Static** (user declares): `covers`, `intent`, `criticality` — semantic metadata
- **Behavioral** (user configures): `on_fail` (analyze/retry/skip), `select` (smart/always/manual) — AI hooks
- **Learned** (Sykli populates): flakiness, avg duration, failure patterns — history hints

### FALSE Protocol Occurrences

All internal events are `%Sykli.Occurrence{}` structs broadcast via Phoenix.PubSub. Types:

`ci.run.started`, `ci.run.passed`, `ci.run.failed`, `ci.task.started`, `ci.task.completed`, `ci.task.cached`, `ci.task.skipped`, `ci.task.retrying`, `ci.task.output`, `ci.cache.miss`, `ci.gate.waiting`, `ci.gate.resolved`

Terminal events get enriched with `error`, `reasoning`, `history` blocks by `Occurrence.Enrichment`.

### .sykli/ Directory (AI's Memory)

```
.sykli/
├── occurrence.json          # latest run (FALSE Protocol, always written)
├── occurrences_json/        # per-run JSON archive (last 20)
├── occurrences/             # ETF archive (last 50, fast BEAM reload)
├── context.json             # pipeline structure + health (via `sykli context`)
├── test-map.json            # file → tasks mapping (via `sykli context`)
└── runs/                    # run history manifests
```

## SDKs

Five SDKs in `sdk/` — Go, Rust, TypeScript, Elixir, Python. All support the full API including semantic metadata, containers, mounts, services, K8s options, caches, secrets, gates, matrix, capabilities.

SDK detection order: `.go` → `.rs` → `.exs` → `.ts` → `.py`

SDKs are run with `--emit`, must output valid JSON to stdout. When changing task schema fields, update all five SDKs.

## CLI Commands

`run`, `validate`, `init`, `explain`, `fix`, `plan`, `context`, `query`, `graph`, `report`, `history`, `verify`, `delta`, `watch`, `daemon`, `mcp`, `cache`

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
- **Elixir heredoc gotcha** — `"""` embeds literal newlines that break JSON. Use `~s()` for single-line JSON in test fixtures
- **~s() with parens gotcha** — `~s()` uses `()` as delimiters, so `~s(matches(x, "y"))` breaks. Use `~s[]` or `~S||` instead

## Git Workflow

- Never push directly to main — use feature branches + PRs
- Branch naming: `feature/<short-description>`
- Push with `-u`, then `gh pr create` targeting main

## Known Issues

- `--timeout` flag doesn't enforce timeouts on local target (tasks run to completion)
- 1 test requires Docker daemon running (skipped when unavailable)
