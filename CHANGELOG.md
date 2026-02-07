# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
