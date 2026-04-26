# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Recent changes

- Cache fingerprint scheme changed to include repo-relative workdir; occurrences from before this change are not backward-compatible.

## What is Sykli?

AI-native CI engine. Pipelines are written as real code (Go/Rust/TypeScript/Elixir/Python SDKs), emitted as JSON task graphs, and executed by an Elixir/BEAM engine. Every run produces structured context (FALSE Protocol occurrences) that AI assistants can read directly — no log parsing.

## Build & Test Commands

All core development happens in `core/` (requires Elixir 1.14+):

```bash
cd core
mix deps.get              # install dependencies (first time)
mix test                  # run all tests
mix test test/sykli/executor_test.exs           # single test file
mix test test/sykli/executor_test.exs:42        # single test at line
mix test --only integration                      # tagged tests
mix format                # format code
mix credo                 # lint (includes custom NoWallClock check)
mix escript.build         # build the sykli binary → core/sykli
./sykli --help            # smoke test the binary
```

SDK conformance tests (validates SDK JSON output against expected cases):
```bash
tests/conformance/run.sh                    # all SDKs, all cases
tests/conformance/run.sh --sdk go           # single SDK
tests/conformance/run.sh case-name          # single case
```

Black-box tests (run against the built binary — cases listed in `test/blackbox/dataset.json`):
```bash
test/blackbox/run.sh              # all cases
test/blackbox/run.sh --verbose    # show failure details
test/blackbox/run.sh --filter=POS # substring-filter case names
```

Eval harness (AI agent evaluation against oracle ground-truth cases):
```bash
eval/oracle/run.sh                          # run all oracle cases against binary
eval/oracle/run.sh --case 001               # single case
eval/oracle/run.sh --category pipeline      # filter by category
eval/oracle/run.sh --verbose                # show command output on failure
eval/harness/run.sh                         # full eval loop (Claude Code → build → oracle → report)
eval/harness/run.sh --case 001 --dry-run    # preview without running
```
`eval/harness/run.sh` requires the `claude` CLI (Claude Code) on PATH; `eval/oracle/run.sh` does not.

### Test tree layout

- `core/test/` — Elixir unit/integration tests run by `mix test`.
- `test/blackbox/` — shell-driven black-box suite against the built `sykli` binary (dataset in `dataset.json`).
- `tests/conformance/` (repo root, note the `s`) — cross-SDK JSON-output conformance cases.
- `eval/oracle/` + `eval/harness/` — ground-truth cases and the AI-agent eval loop.

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
| `CLI` | `cli.ex` | Command dispatch (see CLI Commands section for the list) |
| `Graph` | `graph.ex` | JSON → Task DAG, validation, matrix expansion |
| `Graph.Task` | `graph.ex` + `graph/task/*.ex` | Task struct with semantic/ai_hooks/history fields |
| `Executor` | `executor.ex` | DAG execution with `Executor.Config` struct, AI hooks, concurrency limiting |
| `Executor.Server` | `executor/server.ex` | GenServer wrapper for run tracking + occurrence emission |
| `Target.Local` | `target/local.ex` | Local execution via Runtime (Docker or Shell) |
| `Runtime.*` | `runtime/*.ex` | HOW commands execute — Shell, Docker, Podman (distinct from Target = WHERE) |
| `Occurrence` | `occurrence.ex` | FALSE Protocol event factory (12 types) |
| `Occurrence.Enrichment` | `occurrence/enrichment.ex` | Terminal event enrichment + JSON/ETF persistence |
| `Occurrence.Store` | `occurrence/store.ex` | Three-tier storage: ETS (hot) → ETF (warm) → JSON (cold) |
| `Cache` | `cache.ex` + `cache/*.ex` | Content-addressed caching (SHA256), tiered repository (local + S3) |
| `Error` | `error.ex` | Structured error types with formatter |
| `Mesh` | `mesh.ex` + `mesh/transport/*.ex` | Distributed task dispatch across BEAM nodes (libcluster); pluggable transport (simulator + real) |
| `Runtime.Resolver` | `runtime/resolver.ex` | Priority-chain runtime selection (opts → app env → SYKLI_RUNTIME → auto-detect → Shell); single place runtimes are named |
| `Runtime.Fake` | `runtime/fake.ex` | Deterministic in-memory runtime for tests; no external binaries, no processes |
| `Runtime.Podman` | `runtime/podman.ex` | Rootless Podman runtime |

Other modules in `lib/sykli/`: Context, Explain, Fix, Plan, Query, Delta, MCP.Server, SCM, Services, Telemetry, HTTP, Attestation, Target.K8s.

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

Key env vars (see `cli.ex` and module docs for full details):

- `SYKLI_CACHE_S3_BUCKET` (+ `_REGION`, `_ENDPOINT`, `_ACCESS_KEY`, `_SECRET_KEY`) — enable S3 cache tier
- `SYKLI_SIGNING_KEY` — HMAC-SHA256 key for DSSE attestation envelopes (development only)
- `SYKLI_ATTESTATION_KEY_FILE` — path to signing key file (recommended for production)
- `SYKLI_SOURCE_URI` — override occurrence `source` field (default: `"sykli"`)
- `SYKLI_DRAIN_TIMEOUT_MS` — graceful shutdown drain timeout (default: 30000)
- `SYKLI_K8S_NAMESPACE` — K8s target namespace (default: `"sykli"`)
- `GITHUB_TOKEN` / `GITLAB_TOKEN` / `BITBUCKET_TOKEN` — SCM commit status integration

## Testing Patterns

- Default excludes: `:integration`, `:docker`, `:podman` — all require a real container runtime.
- Run the tiers: `mix test` (unit, against `Sykli.Runtime.Fake`), `mix test.docker`, `mix test.podman`, `mix test.integration`.
- `:test` env sets `config :sykli, :default_runtime, Sykli.Runtime.Fake` so unit tests need no external binaries.
- Some tests use `async: false` due to GenServer state (coordinator, events, delta, watch) or Application/env manipulation (resolver).
- No global test helpers — each test file is self-contained.

## Patterns & Conventions

- **Behaviours over protocols** for targets/runtimes — `Sykli.Target.Behaviour`, `Sykli.Runtime.Behaviour`
- **`run_id` is threaded explicitly** through executor functions — never use Process dictionary
- **Occurrence emission** uses `maybe_emit_*` helpers that pattern-match `nil` run_id to no-op
- **Services** are stateless modules in `services/` — no GenServers, just functions
- **Structured errors** via `Sykli.Error` — never bare strings. Use `Sykli.Error.task_failed/5`, etc.
- **JSON output** — most commands support `--json`. All `--json` output flows through `Sykli.CLI.JsonResponse`, which wraps results in a shared envelope so agents can parse a single shape across commands:
  - Success: `{"ok": true,  "version": "1", "data": <payload>, "error": null}`
  - Error: `{"ok": false, "version": "1", "data": null, "error": {"code", "message", "hints"}}`
  - Failure-with-data (e.g. `validate` finding errors): `{"ok": false, "version": "1", "data": <payload>, "error": null}` — distinguishes a domain-level "no" from an infrastructure-level error
  When adding a new `--json` path, use `JsonResponse.ok/1`, `error/1`, or `error_with_data/1` — never hand-roll an envelope
- **Executor.Config** — executor options flow through `%Executor.Config{}` struct (target, timeout, run_id, max_parallel, continue_on_failure)
- **HTTP with TLS** — all `:httpc` callers use `Sykli.HTTP.ssl_opts/1` for `verify_peer` + hostname checking
- **Cache backend selection** — `Sykli.Cache.repo/0` dynamically selects FileRepository or TieredRepository (L1 local + L2 S3) based on env vars
- **Secret masking** — `SecretMasker.mask_deep/2` applied to occurrence data before persistence and webhook delivery. Env var patterns: `_TOKEN`, `_SECRET`, `_KEY`, `_PASSWORD`, `_URL`, `_DSN`, `_URI`, `_CONN`, etc.
- **S3 circuit breaker** — `TieredRepository` tracks consecutive S3 failures in `persistent_term`; after 5 failures, L2 writes skip for 60s cooldown
- **Async SCM** — `maybe_github_status/2` fires via `Task.Supervisor.async_nolink` (never blocks executor)
- **Path containment** — file reads and Docker mounts must use `String.starts_with?(path, base <> "/")` to prevent path traversal (trailing slash prevents prefix tricks)
- **TLS everywhere** — all `:httpc` calls must include `Sykli.HTTP.ssl_opts/1` (OIDC, S3, SCM, webhooks)
- **Elixir heredoc gotcha** — `"""` embeds literal newlines that break JSON. Use `~s()` for single-line JSON in test fixtures
- **~s() with parens gotcha** — `~s()` uses `()` as delimiters, so `~s(matches(x, "y"))` breaks. Use `~s[]` or `~S||` instead
- **No wall-clock or global RNG in simulator-facing code** — the custom `CredoSykli.Check.NoWallClock` check (`core/lib/credo_sykli/check/no_wall_clock.ex`) fails on `System.monotonic_time/os_time/system_time`, `DateTime.utc_now`, `NaiveDateTime.utc_now`, `:os.system_time`, `:erlang.now`, and bare `:rand.uniform`. Route time through transport APIs (e.g. `now_ms/0`) and randomness through explicit seeded state
- **Runtime isolation** — no module outside `core/lib/sykli/runtime/` may name a specific runtime implementation (`Sykli.Runtime.Docker`, `Podman`, `Shell`, `Fake`, `Containerd`). Selection flows through `Sykli.Runtime.Resolver`. Enforced by `core/test/sykli/runtime_isolation_test.exs` — the test greps the source tree and fails on any offender

## Git Workflow

- Never push directly to main — use feature branches + PRs
- Branch naming: `feature/<short-description>`
- Push with `-u`, then `gh pr create` targeting main

## Known Issues

- `--timeout` flag doesn't enforce timeouts on local target (tasks run to completion)
- Docker-tagged tests are skipped when no Docker daemon is available; run them explicitly with `mix test.docker`.
- See `docs/deep-dive-findings.md` for tracked issues — security (SEC-001–007) and reliability (REL-001–008) items are all resolved; test coverage (TEST-001–010) resolved; architecture items (ARCH-001–010) remain as long-term structural improvements
