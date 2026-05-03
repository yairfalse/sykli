# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Recent changes

- **GitHub-native foundation** shipped — GitHub App auth, webhook receiver (Plug + Bandit), Checks API client, `Sykli.Mesh.Roles`. See `docs/github-native.md`.
- **CLI visual reset** shipped — Nordic-minimal renderer (`Sykli.CLI.Renderer/Theme/Live/FixRenderer`). The output rules are testable; banned vocabulary in §"CLI output rules" below.
- **Cache fingerprint** scheme includes repo-relative workdir; occurrences from before this change are not backward-compatible.

## What is Sykli?

sykli is a compiler for programmable execution graphs. Graphs are written as real code (Go/Rust/TypeScript/Elixir/Python SDKs), emitted as JSON task plans, and executed by an Elixir/BEAM engine. CI is one use case of the graph model; every run also produces structured context (FALSE Protocol occurrences) that agents and downstream tools can read directly — no log parsing.

## Build & Test Commands

All core development happens in `core/` (requires Elixir 1.14+):

```bash
cd core
mix deps.get              # install dependencies (first time)
mix test                  # run all tests (excludes :integration, :docker, :podman by default)
mix test test/sykli/executor_test.exs           # single test file
mix test test/sykli/executor_test.exs:42        # single test at line
mix test.docker           # alias: mix test --only docker
mix test.podman           # alias: mix test --only podman
mix test.integration      # alias: mix test --only integration
mix format                # format code
mix credo                 # lint (includes custom NoWallClock check)
mix escript.build         # dev binary → core/sykli (escript, requires Erlang on PATH)
mix release sykli         # production release via Burrito (self-contained, see RELEASE.md)
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

### Other docs (don't duplicate; defer to)

- `README.md` — user-facing pitch + quickstart.
- `GETTING_STARTED.md` — installation and first-pipeline walkthrough.
- `RELEASE.md` — release process (Burrito builds, signing, tagging).
- `CHANGELOG.md` — Keep-a-Changelog format; current line is 0.6.x.
- `examples/` and `test_projects/` — runnable sample pipelines for manual testing.

Before every commit: `mix format && mix test && mix escript.build`

## Definition of done

Every shipped command or feature must satisfy the dual-surface acceptance criteria in `docs/done.md`: human CLI output and agent-readable JSON/MCP surfaces are co-equal. Treat that document as part of PR review, not aspirational guidance.

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

`Sykli.Application` calls `Sykli.Mesh.Roles.bootstrap_local_roles/0` before starting the supervisor. Then (`:rest_for_one` strategy):
1. `Sykli.ULID` — monotonic ID generation
2. `Phoenix.PubSub` — occurrence broadcasting (`Sykli.PubSub`)
3. `Task.Supervisor` — isolated task execution (`Sykli.TaskSupervisor`)
4. `Sykli.RunRegistry` — tracking active runs
5. `Sykli.GitHub.Webhook.Server` — Bandit listener; idle on nodes that don't hold the `:webhook_receiver` role

The application also installs a SIGTERM handler that drains in-flight `TaskSupervisor` children within `SYKLI_DRAIN_TIMEOUT_MS` (default 30s) before exit.

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
| `Target.Local` | `target/local.ex` | Local execution via Runtime (Docker or Shell) |
| `Runtime.*` | `runtime/*.ex` | HOW commands execute — Shell, Docker, Podman (distinct from Target = WHERE) |
| `Occurrence` | `occurrence.ex` | FALSE Protocol event factory (12 types) |
| `Occurrence.Enrichment` | `occurrence/enrichment.ex` | Terminal event enrichment + JSON/ETF persistence |
| `Occurrence.Store` | `occurrence/store.ex` | Three-tier storage: ETS (hot) → ETF (warm) → JSON (cold) |
| `Cache` | `cache.ex` + `cache/*.ex` | Content-addressed caching (SHA256), tiered repository (local + S3) |
| `Error` | `error.ex` | Structured error types with formatter |
| `Mesh` | `mesh.ex` + `mesh/transport/*.ex` | Distributed task dispatch across BEAM nodes (libcluster); pluggable transport (simulator + real) |
| `Mesh.Roles` | `mesh/roles.ex` | Single-node-per-role capability registry (`acquire/2`, `release/2`, `holder/1`, `held_by_local?/1`). Used to gate the GitHub webhook receiver. |
| `Runtime.Resolver` | `runtime/resolver.ex` | Priority-chain runtime selection (opts → app env → SYKLI_RUNTIME → auto-detect → Shell); single place runtimes are named |
| `Runtime.Fake` | `runtime/fake.ex` | Deterministic in-memory runtime for tests; no external binaries, no processes |
| `Runtime.Podman` | `runtime/podman.ex` | Rootless Podman runtime |
| `CLI.Renderer` / `Theme` / `Live` / `FixRenderer` | `cli/{renderer,theme,live,fix_renderer}.ex` | The v0.6 visual reset. Pure-function renderer + redraw-region driver + Sykli-fix layout. |
| `CLI.JsonResponse` | `cli/json_response.ex` | Shared `--json` envelope (`ok/version/data/error`); all `--json` paths flow through this |
| `GitHub.App` | `github/app/{behaviour,real,fake,cache}.ex` | GitHub App JWT auth + installation token caching; behaviour-split for tests |
| `GitHub.Webhook.{Receiver,Server,Signature,Deliveries}` | `github/webhook/*.ex` | Plug pipeline on Bandit; HMAC-SHA256 signature verification; `X-GitHub-Delivery` replay LRU |
| `GitHub.Checks` | `github/checks.ex` | Checks API client (`create_suite/3`, `create_run/4`, `update_run/4`) |
| `GitHub.Clock` / `GitHub.HttpClient` | `github/{clock,http_client}*.ex` | Behaviour-split time + HTTP layers for deterministic testing |

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

Run lifecycle: `ci.run.started`, `ci.run.passed`, `ci.run.failed`
Task lifecycle: `ci.task.started`, `ci.task.completed`, `ci.task.cached`, `ci.task.skipped`, `ci.task.retrying`, `ci.task.output`
Cache / gates: `ci.cache.miss`, `ci.gate.waiting`, `ci.gate.resolved`
GitHub-native: `ci.github.webhook.received`, `ci.github.check_suite.opened`

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
- `SYKLI_GITHUB_APP_ID` — GitHub App ID for the webhook receiver
- `SYKLI_GITHUB_APP_PRIVATE_KEY` — Path to PEM file (or PEM literal) for App JWT signing
- `SYKLI_GITHUB_WEBHOOK_SECRET` — HMAC secret for webhook signature verification
- `SYKLI_GITHUB_RECEIVER_PORT` — Port the receiver binds (only on the node holding `:webhook_receiver`)
- `GITHUB_TOKEN` / `GITLAB_TOKEN` / `BITBUCKET_TOKEN` — SCM commit status integration (legacy direct-token path superseded by the GitHub App receiver but kept as a documented fallback)

## Testing Patterns

- Default excludes: `:integration`, `:docker`, `:podman` — all require a real container runtime.
- Run the tiers: `mix test` (unit, against `Sykli.Runtime.Fake`), `mix test.docker`, `mix test.podman`, `mix test.integration`.
- `:test` env sets `config :sykli, :default_runtime, Sykli.Runtime.Fake` so unit tests need no external binaries.
- Some tests use `async: false` due to GenServer state (coordinator, events, delta, watch) or Application/env manipulation (resolver).
- No global test helpers — each test file is self-contained.

### Black-box dataset (`test/blackbox/dataset.json`) categories

Cases use prefixed IDs. Original 7 categories: `POS` (positive — works as promised), `NEG` (rejects what it should), `SYS` (cross-boundary behavior), `INT` (SDK-to-engine integration), `PERF` (speed/resources), `LOAD` (volume), `ABN` (abnormal inputs). Phase 2.5 added 6 contract-driven prefixes: `CACHE` (cache contract + isolation), `JSON` (envelope contract), `DET` (determinism / NoWallClock replay contract), `SDK` (cross-language parity), `UI` (visual reset contract — banned vocabulary, glyph language), `GH` (GitHub-native receiver security contract).

Some cases carry `expected_failure: true`, which marks them as known-broken contract assertions hiding open bugs (see `eval/oracle/findings-phase-2-5.md`). When fixing the underlying bug, **remove the flag**; the case must pass naturally without it. Adding new `expected_failure: true` cases is an anti-pattern — open a tracking issue instead.

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

## CLI output rules

The visual reset has output rules that are tested. Touching anything that emits to the terminal must respect them:

- **Glyph language**: `●` passed (cyan-teal) · `○` cache hit (no color) · `✕` failed (red) · `─` blocked / skipped (no color) · `⠋…` running (animated spinner, cyan-teal). Status carried by glyph, not color — colorblind users + screenshots-of-screenshots must still parse the run.
- **One accent color**: cold cyan-teal. Reserved for the success glyph and the spinner. Never on warnings, separators, or decorative use.
- **One summary per run.** Today's old behavior emitted three; that's a regression bug.
- **Banned vocabulary** — these strings must not appear in passing-run output: `"Level"`, `"1L"` (or any `NL`-style line counter), `"(first run)"`, `"Target: local (docker:"`, `"All tasks completed"`. Tests check this.
- **Failure mode** drops a horizontal rule under the failed task, shows the offending stdout/stderr inline (last ~10 lines), and ends with the literal line: `    Run  sykli fix  for AI-readable analysis.`
- **TTY detection**: piping `sykli` output to a file produces zero ANSI escape codes. The renderer falls back to append-only plain text when `not :io.columns/0`-able.

## Project principles

These shape how code decisions get made. They are not aspirational — the test suite enforces several of them directly (CLI output rules, runtime isolation, NoWallClock, secret masking, path containment).

- **Local-first.** The user's hardware is the execution authority. No hosted SaaS, network is opt-in. Anything that requires reaching out to a remote service must work offline by default.
- **Agents are executors, not reviewers.** Claude, Codex, deterministic linters, and review primitives all run as graph nodes — first-class executors with the same interface as build/test tasks. They produce structured output (FALSE Protocol occurrences) the rest of the graph can consume. They are not magic black boxes bolted on the side.
- **Tasks span computation, validation, and reasoning.** "Run tests," "lint the code," and "ask Claude to review the API surface" are all tasks. Each declares inputs, outputs, dependencies, and a deterministic flag. Each can fail.
- **CI is one use case, not the use case.** The execution-graph model is general; CI happens to be the most legible deployment of it. Don't over-couple core code to CI vocabulary.
- **Visual direction is binding.** §"CLI output rules" above is testable and tested. Banned vocabulary, glyph language, accent-color discipline are all enforced.
- **Sandbox the runtime layer.** No module outside `core/lib/sykli/runtime/` may name a specific runtime implementation. Selection flows through `Sykli.Runtime.Resolver`. This is enforced by `core/test/sykli/runtime_isolation_test.exs`.

## Git Workflow

- Never push directly to main — use feature branches + PRs
- Branch naming: `feature/<short-description>`
- Push with `-u`, then `gh pr create` targeting main

## Known Issues

- `--timeout` flag doesn't enforce timeouts on local target (tasks run to completion)
- Docker-tagged tests are skipped when no Docker daemon is available; run them explicitly with `mix test.docker`.
- See `docs/deep-dive-findings.md` for tracked issues — security (SEC-001–007) and reliability (REL-001–008) items are all resolved; test coverage (TEST-001–010) resolved; architecture items (ARCH-001–010) remain as long-term structural improvements
