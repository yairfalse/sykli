# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **GitHub webhook receiver — three Phase 1 correctness gaps.**
  - `POST /webhook` is now gated by `Sykli.Mesh.Roles.held_by_local?(:webhook_receiver)`. Previously only `GET /healthz` was gated; on a multi-node deployment every node would ingest deliveries, burn `delivery_id`s in their local replay caches, and create duplicate check suites/runs.
  - The replay cache no longer permanently loses deliveries when a downstream call fails. Previously, `accept_delivery` inserted the `delivery_id` *before* `installation_token` / `create_suite` / `create_run`, so a transient GitHub 5xx left the entry in cache and GitHub's automatic retry hit `:duplicate_delivery` / 409. The receiver now evicts the `delivery_id` on any post-accept failure; concurrent dedup is preserved by the atomic `:ets.insert_new` in `Deliveries.accept/3`.
  - Request body is bounded to 10 MB (with a 15s read timeout) instead of Plug's default unbounded read. Distinct error codes for `body_too_large` (413) and `body_read_failed` (408).

### Changed

- **GitHub webhook error responses now distinguish missing vs. bad signature.** Missing `X-Hub-Signature-256` returns 400 `github.webhook.missing_signature`; an invalid signature still returns 401 `github.webhook.bad_signature`. Operators can now tell a stripped-header proxy bug apart from a forgery attempt.
- **GitHub webhook catch-all is now 502 `github.webhook.upstream_failure`** for raw upstream errors (was 400 `github.webhook.invalid`). GitHub does not retry 400s, so the previous response misclassified transient upstream failures as permanent client errors and silently dropped them.
- **GitHub task check runs now start in progress.** Per-task GitHub check runs are created with `status: in_progress` directly. The transient queued state and the corresponding `ci.github.check_run.transitioned` queued→in_progress occurrences no longer fire for task runs. Setup-failure check runs (`sykli/source`) keep the queued→completed pattern unchanged.
- **GitHub check-suite occurrence conclusions now follow per-task Checks API conclusions.** Blocked-only suites report `cancelled`, all-skipped suites report `skipped`, and mixed failed/blocked suites still report `failure`.
- **GitHub source-workspace `bytes` now reports disk usage from `du -sk`.** The `ci.github.run.source_acquired` occurrence now includes dotfiles such as `.git/` and reports disk usage instead of summed apparent file size. If the measurement cannot be computed, `bytes` is `null` instead of silently reporting `0`.
- **`Sykli.Mesh.Roles` moduledoc** clarified to make the local-only ETS semantics explicit. The "mesh" name was misleading — the registry is per-node single-holder enforcement, not cluster-coordinated. Multi-node deployments must ensure only one node carries a given role label.

## [0.6.0] - 2026-04-29

This release crystallizes the v0.6 line: a Nordic-minimal CLI, a fully decoupled runtime layer with deterministic-test defaults, SLSA v1.0 supply-chain attestations, an oracle-based AI agent evaluation harness, the FALSE-Protocol-first-class internal model, and the foundation for v0.7's GitHub-native CI integration. v0.5.1, v0.5.2, and v0.5.3 were development tags without CHANGELOG entries; their changes are folded in here.

**Positioning lock-in.** *Local-first CI for the next generation of software developers.* Every architectural decision in this release flows from that thesis. The next line of work — sykli replaces GitHub Actions instead of running inside it, with a webhook receiver running on the user's own mesh — supersedes the older "run inside GitHub Actions + Commit Status API" integration.

### Added

#### CLI & user-facing
- **v0.6 visual reset** — Nordic-minimal CLI. New modules `Sykli.CLI.Renderer`, `Theme`, `Live`, `FixRenderer`. One accent color (cold cyan-teal), glyph-driven status (`● ○ ✕ ─ ⠋`), right-aligned timing column, single redraw region for animations, hidden task stdout by default, single summary per run.
- **`sykli mcp`** — MCP server for AI assistant integration (Claude Code, Cursor, Copilot). 5 tools, stdio transport.
- **`sykli fix`** — AI-readable failure analysis with source context and git diff. Renders inline causality, "where it changed", and proposed remediation.
- **`sykli query`** — structured queries against pipeline / history / health data without an LLM.
- **`sykli plan`** — dry-run execution planning with git-diff-driven task selection.
- **`sykli explain --pipeline`** — AI-readable pipeline structure (levels, critical path).
- **`sykli run --json`** — structured machine-readable output for AI agents and tooling.
- **Shared JSON envelope** — `Sykli.CLI.JsonResponse` provides `{ok, version, data, error}` across every `--json` command, including the `error_with_data` variant for validate-style failures. Agents parse one shape across all commands.
- **`--runtime` CLI flag** + `mix sykli.runtime.info` task for inspecting runtime selection.
- **Improved no-pipeline-found UX** with quick-start hint, language detection across all 5 SDKs, monorepo support (subdirectory detection).
- **README rewrite** for the v0.6 thesis (650 → 220 lines, then re-cut for the visual reset hero).

#### Runtime decoupling (RC.0–RC.7)
- **`Sykli.Runtime.Resolver`** — single source of truth for runtime selection via priority chain (CLI flag → opts → app env → `SYKLI_RUNTIME` env → auto-detect → Shell fallback).
- **`Sykli.Runtime.Fake`** — deterministic in-memory runtime; default for `:test` env so unit tests need no Docker.
- **`Sykli.Runtime.Podman`** — rootless Podman runtime, full parity with the Docker runtime.
- **Runtime isolation invariant** — no module outside `core/lib/sykli/runtime/` may name a specific runtime. Enforced by `core/test/sykli/runtime_isolation_test.exs` which greps the source tree.
- **Test tiers** — `mix test` (unit, against Fake), `mix test.docker`, `mix test.podman`, `mix test.integration`. Default-excludes `:docker`, `:podman`, `:integration` tags.

#### Supply chain & verification
- **SLSA v1.0 provenance attestation** with DSSE envelope signing (`Sykli.Attestation`). Per-run and per-task envelopes.
- **`SYKLI_SIGNING_KEY` / `SYKLI_ATTESTATION_KEY_FILE`** for HMAC and file-based signing keys.
- **`Sykli.HTTP.ssl_opts/1`** — shared TLS verification options for all `:httpc` callers (OIDC, S3, SCM, webhooks).

#### GitHub-native foundation
- **`Sykli.GitHub.App`** — JWT-signed App authentication, installation token acquisition, behaviour split (Real + Fake) with token caching (`Sykli.GitHub.App.Cache`).
- **`Sykli.GitHub.Webhook.Receiver`** — Plug pipeline on Bandit; `/healthz` and `/webhook` endpoints; HMAC-SHA256 signature verification (`Sykli.GitHub.Webhook.Signature`); replay protection via `X-GitHub-Delivery` LRU (`Sykli.GitHub.Webhook.Deliveries`).
- **`Sykli.GitHub.Checks`** — Checks API client (`create_suite/3`, `create_run/4`, `update_run/4`).
- **`Sykli.GitHub.Clock`** + **`Sykli.GitHub.HttpClient`** — behaviour-split time and HTTP layers for deterministic testing.
- **`Sykli.Mesh.Roles`** — single-node-per-role capability registry. New role `:webhook_receiver` placed by capability rules.
- **New occurrence types** — `ci.github.webhook.received`, `ci.github.check_suite.opened`.
- **`docs/github-native.md`** — App registration walkthrough.

#### Mesh & determinism foundation
- **`Sykli.Mesh.Transport.Sim`** — deterministic in-memory mesh transport for simulation testing. Includes `EventQueue`, `Network`, `Rng`, `SimNode`, `State`, `PidRef` submodules.
- **`Sykli.Mesh.Transport.Erlang`** — production OTP-distribution transport.
- **`CredoSykli.Check.NoWallClock`** — custom Credo check; fails on `System.monotonic_time`, `System.os_time`, `System.system_time`, `DateTime.utc_now`, `NaiveDateTime.utc_now`, `:os.system_time`, `:erlang.now`, and bare `:rand.uniform`.

#### Evaluation & quality
- **Oracle eval suite** — 55 ground-truth cases (20 initial + 20 adversarial + 15 mean) for AI-agent CI behavior validation. Run via `eval/oracle/run.sh`.
- **Eval harness** — full Claude Code → build → oracle → report loop via `eval/harness/run.sh` for AI agent regression evaluation.

#### FALSE Protocol & observability
- **FALSE Protocol first-class** — internal events ARE `Sykli.Occurrence` structs (refactor; previously occurrences wrapped events).
- **`chain_id`** — correlates retry chains across occurrences.
- **Configurable `source` URI** via `SYKLI_SOURCE_URI` env or `:sykli, :source` app env.
- **`:errored` task status** — distinct from `:failed` for infrastructure failures (timeouts, OIDC, missing secrets, process crashes). `:failed` gets causality analysis; `:errored` gets infrastructure diagnostics.
- **`.sykli/context.json`** — added project + health sections; documented optional schema.
- **Per-task log paths** in occurrence task entries.
- **ULID run IDs** — monotonic, sortable, replace older random IDs.

### Changed

- **Cache fingerprint includes repo-relative workdir.** Project-scoped cache keys prevent cross-project pollution. **Breaking for occurrences from before this change** — old `.sykli/occurrence.json` payloads are not backward-compatible with the new cache-key format. Re-run pipelines to rebuild local cache state.
- **Dead code removal** — −1102 lines of compiler warnings + unused modules + stale `Sykli.Executor.Server` references.
- **`README.md`** — rewritten for the v0.6 thesis; broken `crates.io` and `hex.pm` badges removed.
- **CLAUDE.md** — extensively updated: supervision tree, errored status, env vars, runtime isolation rule, NoWallClock rule, S3 circuit breaker, async SCM, JSON envelope shape.

### Fixed

- **K8s job lifecycle namespace handling** — uses manifest namespace, not coordinator default; prevents leaks across namespaces.
- **Race condition in `execute_sync`** for fast-completing tasks.
- **Gate occurrence JSON serialization** — gate fields now round-trip through JSON cleanly.
- **Attestation generation without cache metadata** — no longer crashes when cache backend is unconfigured.
- **Circuit breaker monotonic time assertion** — used the wrong time source.
- **xmerl warning configuration** — silenced the noise on stderr.
- **Cache fingerprint collisions** across projects sharing similar task graphs.
- **35+ PR review comments** addressed across the release (Copilot + human reviewers).

### Security

- **SEC-001** — OIDC token requests now verify TLS (was using `:verify_none`).
- **SEC-002** — `secret_refs` file source validates path containment, prevents host-path traversal.
- **SEC-003** — Docker mount paths use `String.starts_with?(path, base <> "/")` to prevent prefix-trick traversals.
- **SEC-004** — Webhook delivery has SSRF guard; rejects internal IP ranges and metadata endpoints.
- **SEC-006** — `SecretMasker` now matches broader env var patterns (`_TOKEN`, `_SECRET`, `_KEY`, `_PASSWORD`, `_URL`, `_DSN`, `_URI`, `_CONN`).
- **SEC-007** — Cache key now includes OIDC-derived runtime secrets to prevent cache leak across credentialed runs.
- **OIDC JWT verification** — full RS256 verification against the provider's JWKS, not just decoding.
- **S3 circuit breaker** — `TieredRepository` tracks consecutive failures in `persistent_term`; after 5, L2 writes skip for 60s cooldown.
- **Async SCM status calls** (REL-005) — status posts fire via `Task.Supervisor.async_nolink` and never block the executor.
- **Webhook signature verification** — HMAC-SHA256, constant-time comparison, body never logged on mismatch.
- **Webhook replay protection** — bounded LRU of `X-GitHub-Delivery` IDs.

### Reliability

- **REL-002** — Graceful shutdown (SIGTERM) drains in-flight tasks within `SYKLI_DRAIN_TIMEOUT_MS` (default 30s).
- **REL-003** — Concurrent runs no longer race on `.sykli/occurrence.json`; writes go through `Occurrence.Store` with three-tier persistence (ETS hot → ETF warm → JSON cold).
- **REL-004** — S3 cache timeout no longer blocks executor; calls are bounded and circuit-broken.
- **REL-006** — PubSub failures no longer silently swallow occurrence emission; structured warning logged.
- **REL-007** — `RunRegistry` evicts terminated runs (was leaking).
- **REL-008** — Telemetry duration units corrected (was emitting microseconds when contract said milliseconds).

### Documentation

- `docs/deep-dive-findings.md` — 37 tracked issues across security/reliability/architecture/test coverage; the SEC and REL series above are the closure.
- `docs/runtimes.md` — runtime selection priority chain.
- `docs/cache-key-investigation.md` — determinism investigation behind the cache fingerprint change.
- `docs/eventqueue-flake-investigation.md` — property-test triage.
- `docs/github-native.md` — Phase 1 setup walkthrough.
- `CODEX_PROMPT_PHASE_1.md` and `CODEX_PROMPT_PHASE_2.md` — kickoff prompts for AI coding agents driving the GitHub-native rollout.

### SDK & ecosystem

- All five SDKs (Go, Rust, TypeScript, Elixir, Python) bumped to 0.6.0 in lockstep.
- Python SDK adds `verify()` for cross-platform verification parity.
- TypeScript, Rust, and Elixir SDKs gain gate support.
- Comprehensive cross-SDK conformance suite added (`tests/conformance/`); resolves cross-SDK divergences.

### Migration notes

- **Old `.sykli/occurrence.json` payloads** are not backward-compatible with the new cache-key format. The first run after upgrading rebuilds cache state automatically; no user action required beyond expecting one cold run.
- **GitHub integration**: the legacy "run inside GitHub Actions + Commit Status API" path remains supported as a documented fallback. The new GitHub-native path (App + webhook receiver) is opt-in via App registration.
- **Tests requiring Docker** are now excluded by default. Run with `mix test.docker` (or `--include docker`) to execute them.
- **`SYKLI_RUNTIME`** env var is the new way to force a specific runtime. CLI `--runtime` takes precedence.

## [0.5.0] - 2026-02-07

### Added

- **Python SDK** - Full-featured SDK with fluent API, validation, explain mode, and 185 tests
  - Fluent builder API matching Go/Rust/TS patterns
  - Fail-fast and deferred validation with "did you mean?" suggestions
  - 3-color DFS cycle detection
  - Pipeline explain mode for human-readable descriptions
  - Core detector support for `sykli.py` files
- **Capability-based dependencies** - Tasks declare what they provide and need
  - `provides("name", "value")` / `needs("name")` across all 5 SDKs
  - Auto-resolved ordering (needer depends on provider)
  - `SYKLI_CAP_*` env var injection for capability values
  - Validation: name format, no self-provide-need, no duplicate providers, no matrix provides
- **Gate tasks** - Approval points that pause the pipeline
  - Strategies: prompt (interactive TTY), env (poll env var), file (poll file)
  - Configurable timeout with default 1 hour
  - Gate events (`gate_waiting`, `gate_resolved`) in pub/sub system
- **OIDC credential exchange** - Keyless auth from CI to cloud providers
  - GitHub Actions and GitLab CI identity token acquisition
  - AWS STS `AssumeRoleWithWebIdentity`
  - GCP Workload Identity Federation (STS + external_account credentials)
  - Azure federated token file
  - Secure temp files (crypto-random names, 0600 permissions, cleanup on completion)
  - Per-provider field validation before HTTP calls
- **Merge queue detection** - Detects GitHub `merge_group` and GitLab merge trains
  - Parses PR numbers, SHAs, and target branch from CI env vars
  - Merge queue context included in `.sykli/context.json`

### Fixed

- `--timeout` CLI flag now propagates to per-task execution timeout
- Go SDK gate serialization (gates were silently dropped from JSON output)
- TypeScript/Python `provides()` preserves empty string values (`!== undefined` / `is not None`)
- `Capability.from_map/1` handles non-map/non-string provides entries without crashing
- `Gate.from_map/1` validates timeout is a positive integer
- `GateService` rejects empty-string `env_var`/`file_path`
- `GateService` uses `:io.columns()` for TTY detection instead of `IO.ANSI.enabled?`
- `CapabilityResolver` guards `Regex.match?` with `is_binary` checks
- `MergeQueueDetector` uses `Integer.parse/1` for safe env var parsing
- Go SDK gate config methods panic when called on non-gate tasks (prevents silent misconfiguration)
- OIDC service validates both GitHub env vars before HTTP request
- OIDC temp files use exclusive create mode to prevent TOCTOU races

## [0.4.0] - 2026-02-04

### Added

- **AI-native task metadata** - All 4 SDKs now support semantic metadata for AI assistants
  - `covers(patterns)` - File patterns this task tests (for smart task selection)
  - `intent(description)` - Human-readable description of task purpose
  - `critical()` / `setCriticality(level)` - Mark task criticality (high/medium/low)
  - `onFail(action)` - AI behavior on failure (analyze/retry/skip)
  - `selectMode(mode)` - Task selection mode (smart/always/manual)
  - `smart()` - Enable smart task selection based on changed files
- **Context generation** - Auto-generates `.sykli/context.json` after every run
  - Pipeline structure with semantic metadata
  - Coverage mapping (which tasks test which files)
  - Last run results with task status and errors
- **`sykli context` command** - Generate AI context file on demand
- **Sykli.Git module** - Pure Elixir git operations (branch, ref, diff) with timeout support
- **K8s PVC cache storage** - Persistent volume claims for Kubernetes target caching
- **Artifact validation** - Pre-execution validation of artifact dependencies

### Changed

- **DDD refactoring** - Core modules reorganized following Domain-Driven Design patterns
  - Typed event structs (RunStarted, TaskCompleted, etc.)
  - Cache repository pattern with Entry domain entity
  - Service extraction (CacheService, RetryService, ConditionService, etc.)
  - Target protocols for pluggable execution backends
  - Task decomposed into value objects (Semantic, AiHooks, HistoryHint)
- TypeScript SDK version aligned to 0.4.0
- Improved git branch detection with timeout fallback

### Fixed

- Type warnings in executor module with proper @spec annotations
- Performance fix in `covers_any?/2` - removed filesystem calls, uses in-memory matching

## [0.2.0] - 2025-12-26

### Added

- **Pure K8s REST API client** - No more kubectl dependency for K8s target
  - Custom auth detection (in-cluster service account, kubeconfig)
  - Typed errors with retry logic for transient failures
  - Job lifecycle management (create, wait, logs, delete)
- **Target abstraction** - Unified interface for execution backends
  - `Local` target for laptop/CI runner execution
  - `K8s` target for Kubernetes cluster execution
  - Same pipeline definition works on both
- **sykli delta** - Run only tasks affected by git changes
- **sykli graph** - DAG visualization (Mermaid/DOT output)
- **Templates** - Reusable task configurations
- **Parallel combinator** - Concurrent task groups (`Parallel("name", task1, task2)`)
- **Chain combinator** - Sequential pipelines (`Chain(task1, task2, task3)`)
- **Output declarations** - Tasks can declare outputs (`Output("name", "./path")`)
- **Artifact passing** - Tasks can consume outputs (`InputFrom(task, "output", "/dest")`)
- **Conditional execution** - `When("branch == 'main'")`
- **DX improvements** - Type-safe conditions, typed secrets, K8s validation
- **Structured errors** - TaskError with hints, duration, and formatted output
- **Distributed observability** - BEAM-powered multi-node awareness

### Changed

- Elixir SDK renamed to `sykli_sdk` on hex.pm
- Improved path traversal prevention in artifact copying

### Fixed

- Burrito binary detection (correct env var check)
- Output flushing in CLI commands
- Volume name collisions in K8s target (hash suffix)
- Path traversal vulnerability in local storage

## [0.1.3] - 2025-12-23

### Added

- Quick start guide when no sykli file found
- Improved help output

### Fixed

- Release workflow: update Zig to 0.15.2 and macOS runner

## [0.1.2] - 2025-12-22

### Added

- Rust SDK with rustfmt formatting

## [0.1.1] - 2025-12-22

### Added

- Initial release with Go, Rust, and Elixir SDKs
- Content-addressed caching (local)
- Container execution with mounts
- GitHub status API integration
- Burrito binary distribution
