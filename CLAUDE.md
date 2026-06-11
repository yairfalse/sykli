# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Recent changes

Most recent first. Older shipped features (Phase 3B `task_type`, Phase 3C `success_criteria`, schema-as-canonical-contract, `target` removed, review nodes) are now load-bearing architecture — see §"SDKs", §"Patterns & Conventions" ("Engine vocabulary modules"), and the `ReviewPrimitive` row in §"Key Modules".

- **Monster Phases B/C/E hardening** (audit remediation, `docs/audit-2026-05-22.md`):
  determinism — `ContractHash` now recursively sorts object keys before hashing,
  and the NoWallClock Credo guard covers all pure contract/output-shaping
  transforms. Security — `Sykli.HTTP.check_token_transport/1` refuses bearer
  tokens over plaintext HTTP to non-loopback coordinators
  (`SYKLI_COORDINATOR_INSECURE=1` is a loud explicit opt-out);
  `Sykli.HTTP.check_ssrf/1` guards gate and notification webhook URLs (blocks
  loopback/link-local/RFC1918 + IPv6 equivalents, checks *all* resolved DNS
  records); coordinator auth adds stateless signed per-team tokens with
  org/team/role claims (minted via `sykli coordinator mint-token`, enforced
  across `TeamCoordinator.Router` reads and writes — the bootstrap token stays
  admin-only); resolved task secret *values* are collected per run and masked
  at occurrence, notification, attestation, and team run-summary boundaries,
  with key-pattern matching centralized in `Sykli.Services.SecretPatterns`.
  OTP — fire-and-forget paths use `Task.Supervisor.start_child` (not
  `async_nolink`), and webhook-replay / installation-token ETS tables are
  created at application start instead of by transient request processes.
- **Monster Phase A CI foundation** wires the full evaluation pyramid into CI:
  Credo, black-box CLI tests, cross-SDK conformance, and merge-to-main oracle
  evals. `mix verify` / `make verify` run the same local path. Black-box
  expected-red cases now require issue URLs, stale SDK expected-red flags are
  retired, `cache stats --json` uses the shared JSON envelope, timeouts classify
  as `:errored`, and `schemas/vocabulary.json` plus
  `scripts/gen-vocab.py --check` guard contract vocabulary across engine,
  schema, SDKs, and conformance fixtures.
- **Team Mode gate approval sync** added Phase 8 coordinator gate metadata: daemons publish waiting gate summaries, reviewers approve or reject through team-scoped CLI calls, heartbeat responses deliver decisions back to the originating daemon session, and `.sykli/outbox/gates/` replays deferred gate publishes.
- **Typed failure semantics + contract slices** make task results self-describing for agents. The executor classifies every terminal result into a `Sykli.FailureSemantics` struct (`class`, `retryable`, `source`, `reason`, `message`; classes include `runtime_failure`, `contract_failure`, `criteria_failure`, `unsupported_target`, `timeout`, `dependency_failure`, `policy_block`, `skipped`, `missing_evidence`, `internal_error`, `unknown`) and attaches a reference-sized `Sykli.ContractSlice` (post-parse snapshot of the declared task semantics that governed the result — never logs/source/artifacts). `Sykli.AgentHints` derives next-step hints from the semantics. All three are persisted in history/occurrences and surfaced through CLI `--json` and MCP, so agents distinguish failure kinds without parsing error strings. See `docs/failure-semantics.md`, `docs/result-contract-slices.md`, and `docs/agent-readable-failure-output.md`.
- **Team Mode run summary sync** added Phase 7 coordinator projection: joined daemons publish metadata-only run summaries to `POST /v1/runs`, the coordinator stores idempotent run records plus node/criteria/review/gate/evidence refs, and `.sykli/outbox/runs/` replays deferred publishes. No logs, source, artifacts, contract bytes, or tokens cross this boundary.
- **Evidence requirements are versioned contract fields.** Pipeline `version: "4"` adds executable-task `evidence_required` declarations. V1 evaluates local file evidence refs on the local shell target, persists `evidence_results`, and fails missing required proof with `missing_evidence`; unsupported requirement/target combinations fail explicitly. See `docs/evidence-requirements.md`.
- **Team Mode foundation** shipped — local work-item and gate-decision stores, `sykli run --work` association with deterministic `contract_hash`, daemon join + heartbeat protocol, self-hosted coordinator skeleton (in-memory store, bearer-token auth), work-item sync via `sykli work ... --team <team>`, deterministic review primitive dispatch (`api_breakage`), and canonical contract hashing. CLI surface: `sykli work`, `sykli gate`, `sykli coordinator`, `sykli daemon join`. The four coordination modes (Local-only / Trusted LAN mesh / Self-hosted coordinator / Hybrid) are normative — see `docs/coordination-modes.md` and the design index under §"Other docs". Phases 0–8 of `docs/team-mode-roadmap.md` are implemented; Phase 9 (Kubernetes deployment) is next.
- **Engine now enforces `version` strictly.** `Sykli.ContractSchemaVersion` (`core/lib/sykli/contract_schema_version.ex`) is the central policy module — it pins supported versions (`"1"`, `"2"`, `"3"`, `"4"`), the current version (`"4"`), and rejects missing/empty/wrong-type/unsupported versions. `Sykli.Graph.parse/1` and `Sykli.Validate.validate_data/1` both call `ContractSchemaVersion.fetch/1`. The previous silent default-to-`"1"` behavior is gone — payloads without a valid version are rejected. Negative coverage lives in `tests/conformance/schema-invalid/`.
- **GitHub-native foundation** shipped — GitHub App auth, webhook receiver (Plug + Bandit), Checks API client, `Sykli.Mesh.Roles`. See `docs/github-native.md`.
- **CLI visual reset** shipped — Nordic-minimal renderer (`Sykli.CLI.Renderer/Theme/Live/FixRenderer`). The output rules are testable; banned vocabulary in §"CLI output rules" below.

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
mix verify                # local CI pyramid: format, test, credo, build, blackbox, conformance
mix release sykli         # production release via Burrito (self-contained, see RELEASE.md)
./sykli --help            # smoke test the binary
```

From the repository root, `make verify` runs the same `core` alias.

SDK conformance tests (validates SDK JSON output against expected cases):
```bash
tests/conformance/run.sh                    # all SDKs, all cases
tests/conformance/run.sh --sdk go           # single SDK
tests/conformance/run.sh case-name          # single case
```
The runner first runs `scripts/validate-conformance-schema.py` against `schemas/sykli-pipeline.schema.json`. The schema step gracefully skips when Python <3.12 or the `jsonschema` package is unavailable. Pin the interpreter with `SYKLI_CONFORMANCE_PYTHON=python3.X` — the runner hard-errors if that explicit value fails the >=3.12 check (rather than silently substituting another interpreter). Auto-detection probes a venv, then `python3.14`/`3.13`/`3.12`/`python3`.

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
- `tests/conformance/cases/` — positive cross-SDK conformance cases. SDKs must emit byte-identical JSON for these.
- `tests/conformance/schema-invalid/` — negative schema-rejection fixtures. The schema validator asserts each one **fails** validation; missing-rejection is itself a failure.
- `tests/conformance/fixtures/<sdk>/` — per-SDK pipeline files for each case in `cases/`.
- `eval/oracle/` + `eval/harness/` — ground-truth cases and the AI-agent eval loop.

### Other docs (don't duplicate; defer to)

- `README.md` — user-facing pitch + quickstart.
- `GETTING_STARTED.md` — installation and first-pipeline walkthrough.
- `RELEASE.md` — release process (Burrito builds, signing, tagging).
- `CHANGELOG.md` — Keep-a-Changelog format.
- `VERSION` (repo root) — canonical version string; `mix.exs` and SDK package manifests mirror it via `scripts/bump-version.sh`. Read this, don't hardcode versions.
- `docs/sdk-schema.md` — current canonical wire contract, field-by-field.
- `docs/agent-contract-semantics.md` — Phase 3 design doc (normative for future Phase 3 PRs).
- `docs/coordination-modes.md` — the four Team Mode shapes (Local / Mesh / Coordinator / Hybrid). Normative.
- `docs/local-state-plane.md` — the `.sykli/` ↔ coordinator split: detailed local truth vs. shared projection.
- `docs/self-hosted-coordinator.md` — coordinator responsibilities, data model (`orgs/teams/members/daemon_sessions/work_items/work_notes/contracts`), and storage.
- `docs/daemon-join-protocol.md` — outbound daemon join + heartbeat + reconnect semantics.
- `docs/team-mode-roadmap.md` / `docs/team-mode-security.md` — phasing and security posture.
- `docs/review-primitives.md` — review-node dispatch contract and the `review_result` shape.
- `docs/failure-semantics.md` / `docs/result-contract-slices.md` / `docs/agent-readable-failure-output.md` — typed failure classification, the result contract slice, and how both surface to agents.
- `docs/runtimes.md` — runtime selection priority chain.
- `docs/runtime-trust-model.md` — the Shell runtime is not a security sandbox (trusted repo code only; use a container runtime for untrusted pipelines); Sykli's own file ops are path-contained. Normative for `GH-004`.
- `docs/vartio-integration.md` — Sykli ↔ Vartio split: Sykli is the execution-contract layer, Vartio the fleet-supervisor/behavioral-envelope layer; integration is evidence-based, not a merger.
- `examples/` and `test_projects/` — runnable sample pipelines for manual testing.

Before every commit: `mix format && mix test && mix escript.build`

The repo ships a pre-commit hook at `.githooks/pre-commit` that runs `sykli delta` (the binary's affected-tasks-only path) against the staged change. It auto-discovers the binary in this order: `./core/sykli` → `./core/burrito_out/sykli_macos_aarch64` → `$PATH`; if none are present it exits 0 (skips). The hook is **not** wired up automatically — enable it with `git config core.hooksPath .githooks`. This is real dogfooding: a regression in `sykli delta` breaks every dev's commit flow, so treat that command as user-visible critical-path behavior.

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

### Coordination modes (Team Mode)

> The daemon executes and records; the mesh dispatches inside trusted networks; the coordinator synchronizes team state across locations; `.sykli/` remains the local source of detailed evidence.

That sentence is normative. It appears verbatim in `docs/coordination-modes.md`, `docs/local-state-plane.md`, and `docs/daemon-join-protocol.md`, and it constrains every Team Mode change. The four shapes:

1. **Local-only.** No network. One machine. The default.
2. **Trusted LAN mesh.** BEAM/libcluster mesh inside a trust domain (existing `Sykli.Mesh`).
3. **Self-hosted coordinator.** Team-state plane. Daemons connect outbound via `Sykli.Daemon.Join` and `Sykli.Coordinator.Client`; the coordinator never executes work.
4. **Hybrid.** Mesh inside trust domains, coordinator across them.

Local-first is binding: anything new must work in mode 1 with no network. The coordinator is a downstream projection of part of `.sykli/` — it never owns detailed evidence (see `docs/local-state-plane.md`).

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
| `WorkItem` / `Work.Store` | `work_item.ex`, `work/store.ex` | Local work-item model + JSON store at `.sykli/work/items/<id>.json`. Statuses: `open/claimed/running/blocked/done/failed/cancelled`. Run association via `attach_run/3`. |
| `GateDecision` / `Gate.Store` | `gate_decision.ex`, `gate/store.ex` | Local gate-decision model + JSON store at `.sykli/gates/<id>.json`. Statuses: `waiting/approved/rejected/blocked/expired`. `decided_by` is a compact actor ref string (e.g. `"member:yair"`). |
| `Coordinator.Client` | `coordinator/client.ex` | `:httpc`-backed JSON transport used by daemons to talk to a self-hosted coordinator (TLS via `Sykli.HTTP.ssl_opts/1`). Per-resource API surfaces (e.g. `WorkClient`) layer on top of this. (The former in-process BEAM-mesh `Sykli.Coordinator`/`Sykli.Reporter` occurrence-aggregation path was retired — Team Mode uses this HTTP coordinator.) |
| `TeamCoordinator.{Application,Router,Auth,Store}` | `team_coordinator/{application,router,auth,store}.ex` | The self-hosted coordinator *server* side: Plug router + in-memory store. `Auth` accepts the bootstrap bearer token as admin and stateless signed per-team tokens (org/team/role claims, minted via `sykli coordinator mint-token`); the router enforces those scopes on every read and write. Never executes work. |
| `TeamCoordinator.WorkClient` / `GateClient` | `team_coordinator/{work_client,gate_client}.ex` | Thin per-resource adapters over `Coordinator.Client`. Power `sykli work ... --team <team>` and team-scoped gate approve/reject. Do not cache locally; do not execute or assign work. |
| `TeamCoordinator.RunSummary` / `RunClient` | `team_coordinator/run_summary.ex`, `team_coordinator/run_client.ex` | Metadata-only run sync projection and coordinator adapter. Publishes run status, nodes, criteria/review summaries, gates, and evidence refs; never logs, source, artifacts, contract bytes, or tokens. |
| `Outbox` | `outbox.ex` | Atomic `.sykli/outbox/<kind>/<id>.json` queue for deferred Team Mode sync. Run summaries use `outbox/runs/`, gate publishes `outbox/gates/`. |
| `Daemon.Join` / `Daemon.SessionStore` | `daemon/join.ex`, `daemon/session_store.ex` | Outbound daemon join + heartbeat protocol (see `docs/daemon-join-protocol.md`). Session token persisted under `.sykli/`. |
| `ReviewPrimitive` | `review_primitive.ex` | Deterministic dispatch for `kind: "review"` nodes. Canonical names only (e.g. `api_breakage`); hyphenated aliases are rejected. Returns `Result{review_type, status, severity, message, tool, findings, evidence}`. Unsupported primitives fail explicitly — never silently skipped. |
| `ContractHash` | `contract_hash.ex` | `sha256:` hashes for emitted SDK JSON. Canonicalizes by re-encoding parsed JSON so formatting and SDK-side comments don't perturb the hash. Used as Team Mode contract identity. |
| `CLI.{Coordinator,Gate,Work}` | `cli/{coordinator,gate,work}.ex` | Subcommand modules for the Team Mode CLI surface. All `--json` output flows through `CLI.JsonResponse`. |
| `FailureSemantics` | `failure_semantics.ex` | Normalized terminal-result classification (`class`, `retryable`, `source`, `reason`, `message`). Independent of the pipeline contract schema. Produced by the executor; `to_map/1` ↔ `from_map/1` round-trip for history/occurrences. Unknown classes degrade to `:unknown`. |
| `ContractSlice` | `contract_slice.ex` | Reference-sized post-parse snapshot of a task's declared semantics (`from_task/1`), stored with result evidence to explain *which contract governed* a result. Never carries logs/source/artifacts/raw output. |
| `AgentHints` | `agent_hints.ex` | Derives agent next-step hints from a `FailureSemantics`. Surfaced in CLI `--json` and MCP alongside the semantics. |

Other modules in `lib/sykli/`: Context, Explain, Fix, Plan, Query, Delta, Simulate, MCP.Server, SCM, Services, Telemetry, HTTP, Attestation, Target.K8s.

See `docs/mcp-tools.md` for the current MCP tool surface, return shapes, composability notes, and audit recommendations.

### TaskResult Status Values

- `:passed` — task ran and succeeded
- `:failed` — task's command returned non-zero exit code (content failure — code is broken)
- `:errored` — infrastructure failure (process crash, timeout, OIDC, missing secrets)
- `:cached` — cache hit, skipped execution
- `:skipped` — condition not met
- `:blocked` — dependency failed

When checking for failures, always match both: `status in [:failed, :errored]`. The distinction matters for AI analysis — `:failed` gets causality analysis, `:errored` gets infrastructure diagnostics. Beyond the coarse status, every terminal result also carries a `failure_semantics` (typed `class`/`retryable`/`source`) and a `contract_slice` (the declared semantics that governed it) — see the "Typed failure semantics + contract slices" entry under §"Recent changes".

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
Team Mode: `ci.team.run.synced`, `ci.team.run.sync_deferred`, `ci.team.gate.requested`, `ci.team.gate.decision_received`, `ci.team.gate.apply_failed`, `ci.team.gate.sync_deferred`, `ci.team.outbox.drained` (public-unstable)

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
├── runs/                    # run history manifests
├── work/items/              # local work items (Team Mode, one JSON per item)
├── gates/                   # local gate decisions (Team Mode, one JSON per decision)
└── outbox/                  # deferred Team Mode sync payloads (runs/, gates/)
```

See `docs/false-protocol-schema.md` for the on-disk schema, sample documents, stability tiers, and producer modules for these artifacts.

## SDKs

Five SDKs in `sdk/` — Go, Rust, TypeScript, Elixir, Python. All support the full API: semantic metadata, containers, mounts, services, K8s options, caches, secrets, gates, matrix, capabilities, **review nodes** (`kind: "review"`), the v3 **`task_type`** and **`success_criteria`** semantic fields, and the v4 **`evidence_required`** field.

**Wire-format version auto-detect** (consistent across all five SDKs): `"4"` if any executable task uses `evidence_required`; else `"3"` if any executable task uses `task_type` or `success_criteria`; else `"2"` if any container/mount/dir/cache resource is used; else `"1"`. Newer versions are supersets of older ones — when v4/v3 features combine with resources, the pipeline emits the newer version *and* a populated `resources` block.

**SDK ↔ engine boundary.** Each SDK is a separate project (`sdk/<lang>/`) with its own dependency tree. SDKs cannot import engine modules — the engine's `Sykli.TaskType` is unreachable from the Elixir SDK at `sdk/elixir/`. Shared vocabulary is owned by `schemas/vocabulary.json` and checked by `scripts/gen-vocab.py --check`. When the canonical contract gains a value, update the manifest, every SDK's local copy, the schema, `Sykli.TaskType`, and the conformance fixtures.

SDK detection order: `.go` → `.rs` → `.exs` → `.ts` → `.py`

SDKs are run with `--emit`, must output valid JSON to stdout. When changing task schema fields, update: (1) `schemas/sykli-pipeline.schema.json`, (2) all five SDK emitters, (3) `Sykli.Graph` parse path + `Sykli.Validate` check path, (4) at least one `tests/conformance/cases/*.json` fixture with per-SDK fixtures.

The project dogfoods itself via `sykli.exs` (root-level pipeline) and `.github/workflows/sykli-ci.yml`.

## CLI Commands

`run`, `validate`, `init`, `explain`, `fix`, `plan`, `context`, `query`, `graph`, `report`, `history`, `verify`, `delta`, `watch`, `daemon`, `mcp`, `cache`, `work`, `gate`, `coordinator`

## Environment Variables

Key env vars (see `cli.ex` and module docs for full details):

- `SYKLI_CACHE_S3_BUCKET` (+ `_REGION`, `_ENDPOINT`, `_ACCESS_KEY`, `_SECRET_KEY`) — enable S3 cache tier
- `SYKLI_SIGNING_KEY` — HMAC-SHA256 key for DSSE attestation envelopes (development only)
- `SYKLI_ATTESTATION_KEY_FILE` — path to signing key file (recommended for production)
- `SYKLI_SOURCE_URI` — override occurrence `source` field (default: `"sykli"`)
- `SYKLI_DRAIN_TIMEOUT_MS` — graceful shutdown drain timeout (default: 30000)
- `SYKLI_K8S_NAMESPACE` — K8s target namespace (default: `"sykli"`)
- `SYKLI_TEAM_TOKEN` — bearer token for Team Mode coordinator sync (work commands, daemon join, run-summary publish). Read from env or CLI `--token`; masked as a secret in occurrence persistence/webhooks — never log or persist it
- `SYKLI_COORDINATOR_INSECURE` — set to `1` to explicitly allow sending the team token over plaintext HTTP to a non-loopback coordinator (logs a loud warning). Without it, `Coordinator.Client` refuses with `{:error, {:insecure_transport, url}}`; HTTPS and loopback never need it
- `SYKLI_GITHUB_APP_ID` — GitHub App ID for the webhook receiver
- `SYKLI_GITHUB_APP_PRIVATE_KEY` — Path to PEM file (or PEM literal) for App JWT signing
- `SYKLI_GITHUB_WEBHOOK_SECRET` — HMAC secret for webhook signature verification
- `SYKLI_GITHUB_RECEIVER_PORT` — Port the receiver binds (only on the node holding `:webhook_receiver`)
- `GITHUB_TOKEN` / `GITLAB_TOKEN` / `BITBUCKET_TOKEN` — SCM commit status integration (legacy direct-token path superseded by the GitHub App receiver but kept as a documented fallback)
- `SYKLI_CONFORMANCE_PYTHON` — pin the Python interpreter `tests/conformance/run.sh` uses for the schema-validation step and Python SDK fixtures. Must be Python ≥3.12 with the `jsonschema` package installed for schema validation to actually run (otherwise the schema step skips with an install hint).

## Testing Patterns

- Default excludes: `:integration`, `:docker`, `:podman` — all require a real container runtime.
- Run the tiers: `mix test` (unit, against `Sykli.Runtime.Fake`), `mix test.docker`, `mix test.podman`, `mix test.integration`.
- `:test` env sets `config :sykli, :default_runtime, Sykli.Runtime.Fake` so unit tests need no external binaries.
- Some tests use `async: false` due to GenServer state (coordinator, events, delta, watch) or Application/env manipulation (resolver).
- No global test helpers — each test file is self-contained.

### Black-box dataset (`test/blackbox/dataset.json`) categories

Cases use prefixed IDs. Original 7 categories: `POS` (positive — works as promised), `NEG` (rejects what it should), `SYS` (cross-boundary behavior), `INT` (SDK-to-engine integration), `PERF` (speed/resources), `LOAD` (volume), `ABN` (abnormal inputs). Phase 2.5 added 6 contract-driven prefixes: `CACHE` (cache contract + isolation), `JSON` (envelope contract), `DET` (determinism / NoWallClock replay contract), `SDK` (cross-language parity), `UI` (visual reset contract — banned vocabulary, glyph language), `GH` (GitHub-native receiver security contract).

Some cases carry `expected_failure: true`, which marks them as known-broken contract assertions hiding open bugs. When fixing the underlying bug, **remove the flag**; the case must pass naturally without it. Adding new `expected_failure: true` cases is an anti-pattern — open a tracking issue instead.

## Patterns & Conventions

- **Behaviours over protocols** for targets/runtimes — `Sykli.Target.Behaviour`, `Sykli.Runtime.Behaviour`
- **`run_id` is threaded explicitly** through executor functions — never use Process dictionary
- **Occurrence emission** uses `maybe_emit_*` helpers that pattern-match `nil` run_id to no-op
- **Services** are stateless modules in `services/` — no GenServers, just functions
- **Structured errors** via `Sykli.Error` — never bare strings. Use `Sykli.Error.task_failed/5`, etc. Public codes are cataloged in `docs/error-codes.md`; add new externally visible codes there with a stability tier before exposing them in JSON, MCP, occurrences, or GitHub Checks.
- **JSON output** — most commands support `--json`. All `--json` output flows through `Sykli.CLI.JsonResponse`, which wraps results in a shared envelope so agents can parse a single shape across commands:
  - Success: `{"ok": true,  "version": "1", "data": <payload>, "error": null}`
  - Error: `{"ok": false, "version": "1", "data": null, "error": {"code", "message", "hints"}}`
  - Failure-with-data (e.g. `validate` finding errors): `{"ok": false, "version": "1", "data": <payload>, "error": null}` — distinguishes a domain-level "no" from an infrastructure-level error
  When adding a new `--json` path, use `JsonResponse.ok/1`, `error/1`, or `error_with_data/1` — never hand-roll an envelope
- **Executor.Config** — executor options flow through `%Executor.Config{}` struct (target, timeout, run_id, max_parallel, continue_on_failure)
- **HTTP with TLS** — all `:httpc` callers use `Sykli.HTTP.ssl_opts/1` for `verify_peer` + hostname checking
- **Cache backend selection** — `Sykli.Cache.repo/0` dynamically selects FileRepository or TieredRepository (L1 local + L2 S3) based on env vars
- **Secret masking** — two complementary mechanisms, both centralized on `Sykli.Services.SecretPatterns` for key matching: (1) `SecretMasker.mask_deep/2` redacts secret-*shaped* keys (`_TOKEN`, `_SECRET`, `_KEY`, `_PASSWORD`, `_URL`, `_DSN`, `_URI`, `_CONN`, etc.); (2) the executor collects each run's *resolved* secret values and masks those exact strings at every egress boundary — occurrence persistence, notifications/webhooks, attestations, and team run summaries. New egress paths must apply both.
- **S3 circuit breaker** — `TieredRepository` tracks consecutive S3 failures in `persistent_term`; after 5 failures, L2 writes skip for 60s cooldown
- **Async SCM** — `maybe_github_status/2` fires via `Task.Supervisor.async_nolink` (never blocks executor)
- **Path containment** — file reads and Docker mounts must use `String.starts_with?(path, base <> "/")` to prevent path traversal (trailing slash prevents prefix tricks)
- **TLS everywhere** — all `:httpc` calls must include `Sykli.HTTP.ssl_opts/1` (OIDC, S3, SCM, webhooks)
- **Outbound URL guards** — user/pipeline-supplied webhook URLs (gates, notifications) must pass `Sykli.HTTP.check_ssrf/1` before any request (blocks loopback, link-local, RFC1918, IPv6 equivalents, IPv4-mapped; checks every resolved DNS record). Token-bearing coordinator calls must pass `Sykli.HTTP.check_token_transport/1`. New outbound HTTP paths should reuse these helpers, not re-derive the checks
- **Elixir heredoc gotcha** — `"""` embeds literal newlines that break JSON. Use `~s()` for single-line JSON in test fixtures
- **~s() with parens gotcha** — `~s()` uses `()` as delimiters, so `~s(matches(x, "y"))` breaks. Use `~s[]` or `~S||` instead
- **No wall-clock or global RNG in simulator-facing code** — the custom `CredoSykli.Check.NoWallClock` check (`core/lib/credo_sykli/check/no_wall_clock.ex`) applies to mesh transport, the pure contract & output-shaping transforms (graph parsing/validation, the vocabulary modules, contract hashing, occurrence serialization), the custom Credo check, and its fixtures/tests as configured in `core/.credo.exs`. Engine modules that legitimately stamp wall-clock time (occurrence factory, run history, cache, OIDC, coordinator) are intentionally out of scope — output determinism for those is guarded by the determinism tests, not this lint. It fails on `System.monotonic_time/os_time/system_time`, `DateTime.utc_now`, `NaiveDateTime.utc_now`, `:os.system_time`, `:erlang.now`, and bare `:rand.uniform`. Route simulator time through transport APIs (e.g. `now_ms/0`) and randomness through explicit seeded state. Duration measurement in executor/target code is allowed when it is reported as elapsed runtime rather than simulator state; see timeout/duration coverage in `core/test/sykli/target/local_test.exs` and executor success-criteria tests for non-simulator elapsed-time usage.
- **Runtime isolation** — no module outside `core/lib/sykli/runtime/` may name a specific runtime implementation (`Sykli.Runtime.Docker`, `Podman`, `Shell`, `Fake`, `Containerd`). Selection flows through `Sykli.Runtime.Resolver`. Enforced by `core/test/sykli/runtime_isolation_test.exs` — the test greps the source tree and fails on any offender
- **Schema is the canonical contract for SDK emission.** `schemas/sykli-pipeline.schema.json` is strict (`additionalProperties: false`) and gates new fields by `version`. The engine in `graph.ex` is more permissive (legacy compatibility paths: unknown keys ignored, `condition` aliasing `when`, list-form `outputs`). SDK output must validate against the schema; engine acceptance is *not* the SDK's bar. Document permissive paths in `docs/sdk-schema.md` under "Contract boundary".
- **Engine vocabulary modules** — values shared across `graph.ex` and `validate.ex` (closed enums, version policies, criterion type sets) live in dedicated modules. The pattern: each such module exposes a `valid?/1` (or `fetch/1`) plus a `format_error/1` and/or `to_error_map/1` so both the parse path and the validate path render errors identically. Existing instances:
  - `Sykli.TaskType` — the 12-value `task_type` enum (Phase 3B).
  - `Sykli.SuccessCriteria` — `success_criteria` shape, constraints, and target-level result helpers (Phase 3C).
  - `Sykli.EvidenceRequirement` — `evidence_required` shape, constraints, result helpers, and missing/unsupported proof semantics.
  - `Sykli.ContractSchemaVersion` — supported `version` values + missing/empty/wrong-type/unsupported error policy.

  When adding a new closed-enum field or shared-policy concept, follow this pattern. SDKs must carry their own copies (separate Mix projects — engine modules are unreachable from `sdk/<lang>/`).
- **Engine error formatting** — parse-time errors render via `Sykli.Graph.format_error/1` (also delegated to from `Sykli.MCP.Tools`); validate-time errors render via `Sykli.Validate.format_errors/1`. Both paths prefix rendered strings with `"Error: "`. Keep new error tuples consistent with the path that produces them.

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

- Docker-tagged tests are skipped when no Docker daemon is available; run them explicitly with `mix test.docker`.
