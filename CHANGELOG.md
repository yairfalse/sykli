# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Pipeline schema v5 parser/validator support.** The engine and canonical
  schema now accept `version: "5"` payloads with executable-task `actor` and
  `mandate` declarations. Agent actors require a mandate, non-empty
  `success_criteria`, and non-empty `evidence_required`; review nodes reject
  the new executable-task fields. SDK emission remains on the existing v4 path.
- **`sykli lock`.** Writes `sykli.lock` with the canonical contract and
  enforces matching locked contracts in `sykli validate` and `sykli run`.
- **`sykli contract`.** Renders the current emitted contract and supports
  `--diff` against `sykli.lock` or another lockfile with weakening
  classification.
- **Daemon heartbeat loop (Monster Phase D, PR 1).** New
  `Sykli.Daemon.Heartbeat` GenServer implements the runtime side of
  `docs/daemon-join-protocol.md`: coordinator-owned cadence
  (`next_heartbeat_seconds`), exponential backoff with jitter capped at
  `heartbeat_interval_seconds * 4`, hard stop on 401/403
  (`team.token.revoked` — the token is never retried), refusal of
  assignments without `accepts_remote_work`, gate-decision application with
  acknowledgement on the following tick, outbox drain on reconnect, and
  liveness fields (`last_heartbeat_at`, `consecutive_failures`) persisted to
  the session file.
- **Heartbeat hosts (Monster Phase D, PR 2).** `sykli daemon join --stay`
  runs the heartbeat loop in the foreground with no BEAM distribution — the
  minimal Team Mode daemon. The mesh daemon (`sykli daemon start`) now also
  hosts the loop as a supervised child for every role; it self-ignores when
  no coordinator session is joined. `sykli daemon status` shows heartbeat
  liveness (`last heartbeat`, consecutive failures, token-revoked) in human
  output; `--json` carries the same fields inside `coordinator_session`.
  New error code: `daemon.stay_failed`.
- **`sykli daemon leave`.** The inverse of `daemon join`: sends a
  best-effort final `offline` heartbeat (when a team token is available)
  and removes the local session file. Idempotent — leaving without a
  session reports `left: false` and exits 0; a down coordinator never
  blocks the local teardown. New error codes:
  `daemon.invalid_leave_command`, `daemon.leave_failed`.
- **Heartbeat resilience (Monster Phase D, PR 3).** The loop now rejoins
  automatically when the coordinator forgets its session
  (`coordinator.daemon_session_not_found` — same daemon identity, fresh
  `session_id`, immediate next tick) and sends a best-effort final
  `offline` heartbeat on graceful shutdown. New black-box case
  `COORD-006` proves the remote gate-approval round-trip end to end
  against the built binary: coordinator decision → heartbeat delivery →
  local gate store approved. This closes the 2026-05-22 audit's "live
  layer is a stub" finding.

### Fixed

- **Coordinator gate-decision lifecycle (closes #202, #205).** Sessions
  silent past the protocol's resume cutoff (default 300s, configurable via
  the store's `session_expiry_seconds`) are pruned together with their
  decision-delivery queues on join and heartbeat. Delivery state now lives
  on the gate record (`acknowledged_at`, `daemon_id`), making queues a
  disposable cache: a daemon rejoining after its old session was pruned
  receives decided-but-unacknowledged gates re-enqueued from the gate
  records; acknowledged decisions are never redelivered. Separately, a
  coordinator session record with corrupt/missing team metadata now
  reports `gate.invalid_session` (500) instead of masquerading as
  `gate.team_mismatch` (403). All `gate.*` coordinator codes are now
  cataloged in `docs/error-codes.md`.

### Changed

- **`sykli --help` tagline aligned with the project positioning.** The
  binary now introduces itself as "execution contracts for agent work"
  (previously "CI pipelines in your language"), matching the README.
- **Team Mode outbox drain extracted to `Sykli.TeamCoordinator.OutboxDrain`.**
  The CLI post-run sync and the heartbeat loop now replay
  `.sykli/outbox/{runs,gates}/` through one shared code path.

## [0.7.0] - 2026-06-11

### Added

- **CONTRIBUTING.md.** Practical contributor guide: build/test tiers, the
  tested-and-enforced project rules (schema-as-contract, vocabulary drift
  guard, runtime isolation, NoWallClock, CLI output rules, dual-surface
  done), and good first contributions.

- **Per-team coordinator authorization (Monster Phase C, C2).** The
  self-hosted coordinator now supports stateless signed team tokens via
  `sykli coordinator mint-token --org <slug> --team <slug> --role
  <role>`. The existing coordinator token remains the admin bootstrap
  token, while team tokens are scoped to their org/team and role.
- **Monster Phase A CI foundation.** CI now runs the full evaluation pyramid:
  Credo, black-box CLI tests, cross-SDK conformance, and merge-to-main oracle
  evals. Local developers can reproduce the same path with `cd core && mix verify`
  or `make verify`.
- **Vocabulary drift guard.** `schemas/vocabulary.json` is now the canonical
  vocabulary manifest, `scripts/gen-vocab.py --check` verifies committed
  engine/schema/SDK copies against it in local verify and CI, and the task-type
  conformance case now exercises every supported value.
- **TypeScript `k8sRaw` object overload.** Advanced Kubernetes fields can now
  be passed as a structured object instead of an escaped JSON string, e.g.
  `.k8sRaw({ nodeSelector: { gpu: "true" } })`.
- **SDK contract cleanup release note.** `docs/releases/0.6.2-contract-cleanup.md` summarizes the Phase 1 through Phase 2C contract cleanup: canonical schema, schema-validated conformance fixtures, `version` semantics, `target` removal, TypeScript K8sOptions narrowing, Python conformance interpreter detection, and experimental review-node support across SDKs.

### Changed

- **Black-box expected-red handling is now issue-backed.** The harness fails an
  `expected_failure` case that lacks an `issue` URL, reads the expected CLI
  version from `VERSION`, supports per-case toolchain `requires`, and retires
  stale SDK expected-red flags.
- **Timeouts classify as infrastructure errors.** Task timeouts now surface as
  `:errored` results instead of content failures.
- **Monster Phase B — `NoWallClock` determinism guard widened.** The custom Credo
  check now also covers pure contract and output-shaping transforms (graph
  parsing/validation, the vocabulary modules, contract hashing, and occurrence
  serialization), not just simulator transport. Time-stamping engine modules
  (occurrence factory, run history, cache, OIDC, coordinator) stay intentionally
  exempt — a CI engine records real time; output determinism is guarded by tests.
- **DET-003 black-box case corrected.** It now asserts occurrence determinism from
  clean state (two fresh workspaces) and strips the run_id-bearing log path. The
  engine was already deterministic; the prior case reused `.sykli/` (so the second
  run was a cache hit) and under-stripped, masking the real contract.

### Fixed

- **Repository paths point at the current GitHub org.** The Go SDK module
  path is now `github.com/false-systems/sykli/sdk/go`, and `install.sh`,
  the GitHub Action, docs, examples, `sykli init` scaffolding, and error
  hints all reference `false-systems/sykli` instead of the pre-transfer
  `yairfalse/sykli`. Go SDK versions up to `sdk/go/v0.4.0` remain
  permanently fetchable under the old module path via the Go module proxy;
  versions from this release onward publish only under
  `github.com/false-systems/sykli/sdk/go` — update your import when you
  upgrade.
- **Coordinator team isolation is enforced (Monster Phase C, C2).** Team
  tokens can no longer widen list filters or read/mutate another team's
  work items, run summaries, gates, or daemon sessions. Gate decisions
  require `owner` or `approver`; `member` tokens receive
  `coordinator.forbidden`.
- **Runtime-resolved secrets are masked (Monster Phase C, C3).** The engine now
  carries per-run resolved secret values from `secret_refs`, OIDC credential
  exchange, and literal secret-like task env keys into occurrence persistence,
  notification payloads, run-summary sync/outbox payloads, and SLSA
  attestations. Secret-pattern matching is centralized and structured payloads
  also redact values under secret-like keys.
- **Runtime trust model documented; GH-004 reframed (Monster Phase C, C5).** New
  `docs/runtime-trust-model.md` states the trust boundary: the Shell runtime is
  **not** a security sandbox (it runs trusted repository code with the invoking
  user's privileges; use a container runtime for untrusted pipelines), while
  Sykli's *own* file operations stay path-contained. The black-box `GH-004` case
  now asserts that real guarantee — a `success_criteria` path that traverses the
  workdir is rejected with `path escapes task workdir` — instead of an unmet
  command-sandboxing assumption. This retires the **last** `expected_failure`
  case; the black-box suite now has zero known-broken cases.
- **Gate webhooks are SSRF-guarded (Monster Phase C, C4).** A pipeline-declared
  gate `webhook_url` is now resolved and rejected if it points at a loopback,
  link-local (incl. the cloud metadata range `169.254.0.0/16`), or private
  address — closing an SSRF/metadata-exfiltration sink. The check is the new
  shared `Sykli.HTTP.check_ssrf/1`, extracted from the existing notification
  webhook guard so both paths enforce identical blocking (IPv4 + IPv6).
- **Coordinator client refuses plaintext token transmission (Monster Phase C, C1).**
  `Sykli.Coordinator.Client` now refuses to send the Team Mode bearer token over
  plaintext HTTP to a non-loopback host — it returns `{:error, {:insecure_transport,
  url}}` and logs an error instead of leaking the token on the wire. HTTPS and
  loopback hosts are unaffected; `SYKLI_COORDINATOR_INSECURE=1` is an explicit
  opt-in (with a loud warning). All token-bearing paths (work/run/gate clients and
  daemon join) route through this client; `Sykli.HTTP.check_token_transport/1` is
  the shared decision.
- **OTP hardening (Monster Phase E).**
  - Fire-and-forget side effects (GitHub commit-status updates, async S3 cache
    writes) use `Task.Supervisor.start_child` instead of `async_nolink`, so
    long-lived callers (e.g. the MCP server) no longer accumulate unconsumed
    `{ref, result}`/`{:DOWN, ...}` task reply messages.
  - `Sykli.Coordinator.connected_nodes/0` derives connectivity from `Node.list/0`
    instead of blocking `Node.ping/1` inside a GenServer callback, which could
    wedge the coordinator past the call timeout and cascade `:timeout` crashes.
  - Webhook replay-protection and installation-token ETS tables are created at
    application start (owned by a long-lived process) rather than lazily by a
    transient request process — they no longer silently reset on request churn.
- **`sykli cache stats --json` now returns a JSON envelope.** The cache stats
  command supports `--json` through `Sykli.CLI.JsonResponse`, and the black-box
  suite asserts the JSON shape instead of only checking for absent ANSI output.
- **Black-box version checks no longer drift.** POS-006 substitutes the root
  `VERSION` value instead of hardcoding an old release string.
- **Stable `contract_hash` canonicalization.** `Sykli.ContractHash.from_json/1`
  recursively sorts object keys before hashing, so semantically-identical
  contracts hash identically regardless of map iteration order. Maps with >32 keys
  previously used a hashed representation whose iteration order is not guaranteed
  stable across OTP versions, which could yield divergent hashes for the same
  contract.

### Removed

- **In-process BEAM-mesh occurrence aggregation retired (`Sykli.Reporter` + `Sykli.Coordinator`).** The worker→coordinator forwarder (`Reporter`) was started by no supervisor, and its consumer (the in-process `Coordinator` GenServer, started in daemon coordinator/full mode) therefore had no producer and no query consumers. Both modules and the daemon wiring were removed; Team Mode coordination uses the self-hosted HTTP coordinator (`Sykli.Coordinator.Client` → `POST /v1/...`), which is unaffected. Daemon `:coordinator`/`:full` roles still differ in execution eligibility; they simply no longer start the dead GenServer.
- **`target` field removed from canonical SDK-emitted pipeline JSON.** All five SDKs no longer serialize `target`, and the JSON Schema rejects it as an unknown task field. The engine never read `target` (the parser ignored it and the executor did not honor it), so removing it is contract cleanup, not a behavior change. SDK builder methods (`.target(...)` / `Target(...)`) are kept as deprecated no-ops so existing call sites still compile; downstream tooling that grepped emitted JSON for `"target":` will need to use concrete execution requirement fields (`container`, `resources`, `mounts`, `k8s`, `services`, `workdir`, `env`) instead. The Python builder now also raises a `DeprecationWarning` on call.

## [0.6.1] - 2026-05-05

### Fixed

- **Go SDK output emission no longer leaks typed nil values.** Empty task outputs now omit the `outputs` field instead of serializing a non-null typed-nil value, restoring cross-SDK conformance for output-free task graphs.
- **Elixir SDK graph emission no longer corrupts stdout with Logger output.** SDK package config keeps emit-path stdout JSON-only by silencing Logger below warning and routing console logs to stderr; SDK consumers can override this in their application config.
- **GitHub dispatcher source workspaces are cleaned up after crashes and normal exits.** A monitored workspace janitor removes cloned webhook source directories even if the dispatcher process dies before its ordinary cleanup path.
- **GitHub webhook receiver — three Phase 1 correctness gaps.**
  - `POST /webhook` is now gated by `Sykli.Mesh.Roles.held_by_local?(:webhook_receiver)`. Previously only `GET /healthz` was gated; on a multi-node deployment every node would ingest deliveries, burn `delivery_id`s in their local replay caches, and create duplicate check suites/runs.
  - The replay cache no longer permanently loses deliveries when a downstream call fails. Previously, `accept_delivery` inserted the `delivery_id` *before* `installation_token` / `create_suite` / `create_run`, so a transient GitHub 5xx left the entry in cache and GitHub's automatic retry hit `:duplicate_delivery` / 409. The receiver now evicts the `delivery_id` on any post-accept failure; concurrent dedup is preserved by the atomic `:ets.insert_new` in `Deliveries.accept/3`.
  - Request body is bounded to 10 MB (with a 15s read timeout) instead of Plug's default unbounded read. Distinct error codes for `body_too_large` (413) and `body_read_failed` (408).

### Changed

- **Conformance runner is environment-aware for Python.** Local runs skip Python SDK cases when Python <3.12 is installed and print the coverage gap up front; CI treats that skip as a failure so Python coverage cannot silently disappear.
- **Six oracle/blackbox expected failures were retired by real SDK fixes.** The fixed Go and Elixir SDK regressions allow the conformance-related expected-red cases to run as normal passing coverage.
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

- `docs/runtimes.md` — runtime selection priority chain.
- `docs/github-native.md` — Phase 1 setup walkthrough.

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
