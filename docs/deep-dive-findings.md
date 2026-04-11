# Sykli Deep Dive Findings — 2026-03-19

Comprehensive analysis from 4 parallel audits: DDD, Architecture, Security, Test Coverage.

Updated 2026-04-10 with resolution status.

## Priority 1: Security (Critical)

### SEC-001: OIDC token requests have no TLS verification — RESOLVED
- **File**: `services/oidc_service.ex` lines 72, 138, 198
- **Impact**: MITM can steal cloud credentials on shared runners
- **Fix**: Add `Sykli.HTTP.ssl_opts(url)` to 3 `:httpc.request` calls
- **Status**: Fixed in commit `94b1f43`. All `:httpc` calls now use `Sykli.HTTP.ssl_opts/1`.

### SEC-002: secret_refs file source reads arbitrary paths — RESOLVED
- **File**: `executor.ex:882`
- **Impact**: Malicious task graph can read `/etc/shadow`, K8s tokens
- **Fix**: Apply existing `path_within?/2` guard before `File.read`
- **Status**: Fixed. Path guard with trailing slash check on `executor.ex:912`.

### SEC-003: Docker mounts allow host path escape — RESOLVED
- **File**: `target/local.ex:378`, `runtime/docker.ex:167`
- **Impact**: Task can mount `/` into container
- **Fix**: Apply `path_within?/2` to mount host paths
- **Status**: Fixed. Both `local.ex:393` and `docker.ex:169` validate mount paths.

### SEC-004: Webhook delivery has no SSRF guard — RESOLVED
- **File**: `services/notification_service.ex:37`
- **Impact**: Attacker-controlled webhook URL can hit AWS metadata endpoint
- **Fix**: Block private IP ranges, loopback addresses
- **Status**: Fixed in commit `94b1f43`. `validate_url_not_private/1` blocks IPv4/IPv6 private ranges.

### SEC-005: Erlang distribution exposed via UDP gossip — DOCUMENTED
- **File**: `daemon.ex:501`, `cluster.ex:50`
- **Impact**: Node identity broadcast on LAN, no TLS on distribution
- **Fix**: Document SYKLI_COOKIE requirement, consider TLS distribution
- **Status**: SYKLI_COOKIE read from env in `daemon.ex:337`. TLS distribution is an operator concern — documented but not enforced in code.

### SEC-006: SecretMasker misses non-standard secret names — RESOLVED
- **File**: `occurrence/enrichment.ex:816`
- **Impact**: Secrets with names like DATABASE_URL appear unmasked
- **Fix**: Collect secrets from task.secret_refs + task.secrets, not just env patterns
- **Status**: Fixed in commit `a177f59`. Broad env patterns: `_TOKEN`, `_SECRET`, `_KEY`, `_PASSWORD`, `_URL`, `_DSN`, `_URI`, `_CONN`, etc.

### SEC-007: Cache key doesn't cover OIDC-derived runtime secrets — RESOLVED
- **File**: `cache.ex:37`, `executor.ex:519`
- **Impact**: Cache hit serves stale output when credentials rotate
- **Fix**: Include secret_refs key names in cache key hash
- **Status**: Fixed. `cache.ex` includes `hash_secret_refs(task.secret_refs)` in cache key computation.

## Priority 2: Reliability (High)

### REL-001: Executor.Server uses Task.start_link — crash kills GenServer — N/A
- **File**: `executor/server.ex:111`
- **Status**: Module `executor/server.ex` no longer exists. Executor uses `Task.Supervisor.async_nolink` (executor.ex:314).

### REL-002: No graceful shutdown (SIGTERM) — RESOLVED
- **File**: `application.ex`
- **Impact**: Docker containers and K8s Jobs orphaned on kill
- **Status**: Fixed. `application.ex:63-71` registers SIGTERM handler. `drain_in_flight_tasks/0` waits up to `SYKLI_DRAIN_TIMEOUT_MS` (default 30s).

### REL-003: Concurrent runs race on occurrence.json — RESOLVED
- **File**: `occurrence/enrichment.ex:609`
- **Impact**: Two `sykli run` invocations overwrite each other's output
- **Status**: Fixed. Atomic write via tmp file + `File.rename` (enrichment.ex:605-613). Per-run files in `occurrences_json/`.

### REL-004: S3 cache timeout blocks executor — RESOLVED
- **File**: `cache/tiered_repository.ex:43`
- **Impact**: 30s timeout per task when S3 unreachable, 20 tasks = 10min stall
- **Status**: Fixed in commit `94b1f43`. Circuit breaker (5 failures → 60s cooldown) + async L2 writes.

### REL-005: SCM status calls synchronous per-task, no rate limiting — RESOLVED
- **File**: `executor.ex:854`, `github.ex:33`
- **Impact**: 50 tasks = 100 API calls, GitHub rate limit exhaustion
- **Status**: Fixed in commit `a177f59`. SCM calls now async via `Task.Supervisor.async_nolink`.

### REL-006: PubSub failure silently swallows occurrence emission — RESOLVED
- **File**: `occurrence/pubsub.ex:125`
- **Impact**: PubSub crash = no occurrences emitted, no fallback
- **Status**: Fixed. Broadcast return value checked, errors logged.

### REL-007: RunRegistry never evicts — RESOLVED
- **File**: `run_registry.ex:99`
- **Impact**: Long-running daemon leaks memory indefinitely
- **Status**: Fixed. `@max_completed_runs` = 500, eviction on every run completion (run_registry.ex:126-166).

### REL-008: Telemetry duration units wrong — RESOLVED
- **File**: `telemetry.ex:91`
- **Impact**: Logged durations are 1,000,000x too large (native units logged as ms)
- **Status**: Fixed. `System.convert_time_unit(duration, :native, :millisecond)` on telemetry.ex:91.

## Priority 3: Architecture (Structural)

These are long-term structural improvements, not bugs. Listed for future refactoring consideration.

### ARCH-001: "Run" is not a first-class aggregate
- No authoritative Run struct owns lifecycle, status, results
- Split across RunHistory.Run, Coordinator maps, Occurrence, Executor.Config

### ARCH-002: "Pipeline" doesn't exist as a domain concept
- No Pipeline entity with name, version, history, ownership
- Commands operate on "the last run" not "pipeline X"

### ARCH-003: Executor couples directly to SCM, Cache, OIDC, Secrets
- 5 concrete service imports, no behaviours/interfaces
- Can't test or swap implementations without module mocking

### ARCH-004: Enrichment crosses 3 bounded contexts
- Imports GitContext, RunHistory, CausalityService directly
- No anti-corruption layer between observation and SCM/history

### ARCH-005: Dual history stores (RunHistory + Occurrence)
- Both track same run data in different formats
- HistoryAnalyzer reads RunHistory to feed Occurrence — one-way flow, intentional design

### ARCH-006: TaskResult means 3 different things
- Executor.TaskResult (6 statuses), RunHistory.TaskResult (3), Coordinator (3 different)
- Lossy translation in sykli.ex:428 discards :errored and :cached

### ARCH-007: Executor.Server reimplements execution — N/A
- Module `executor/server.ex` no longer exists. Finding is stale.

### ARCH-008: CLI contains target setup logic
- cli.ex:154 performs K8s git validation in the presentation layer
- Should be in Target.K8s.setup

### ARCH-009: Four config mechanisms, no catalog
- Env vars, app config, CLI flags, task-level fields
- Three independent default timeout values in different modules

### ARCH-010: Executor.Mesh is a Target in the Executor namespace
- executor/mesh.ex implements Target.Behaviour but lives in executor/
- Namespace tells one story, type system tells another

## Priority 4: Test Coverage

### TEST-001: Occurrence.Enrichment — RESOLVED
- Added `enrichment_test.exs` with 28 tests covering error/reasoning/history blocks, persistence, and cross-run data.

### TEST-002: GateService — RESOLVED
- Added `gate_service_test.exs` with 17 tests covering env, file, prompt, and webhook strategies.

### TEST-003: S3Signer — RESOLVED
- Added `s3_signer_test.exs` with 14 tests covering AWS SigV4 header format, content hashing, methods, and config validation.

### TEST-004: TieredRepository — RESOLVED
- Added `tiered_repository_test.exs` with 10 tests covering circuit breaker state, threshold, cooldown, and reset.

### TEST-005: OIDCService — RESOLVED
- Added `oidc_service_test.exs` covering exchange/2, token acquisition, JWT decode, and temp file cleanup.

### TEST-006: Executor.run/3 — no direct unit test
- Executor is tested via integration through CLI and blackbox tests. Direct unit test deferred due to complexity of mocking full execution pipeline.

### TEST-007: SCM providers — RESOLVED
- Added `github_test.exs` covering enabled?/0, detect_provider/0, and SCM delegation.

### TEST-008: ConditionService — RESOLVED
- Added `condition_service_test.exs` covering should_run?/1, build_context/0, get_branch/0, get_tag/0.

### TEST-009: NotificationService — RESOLVED
- Added `notification_service_test.exs` covering configured_urls/0, SSRF guards, Slack/generic format detection.

### TEST-010: RetryService — RESOLVED
- Added `retry_test.exs` covering retry configuration, on_fail boost logic, and max_attempts calculation.

### TEST-011: Zero property-based testing (StreamData not in deps)
- Open. StreamData dependency not added. Consider for future test quality improvement.

### TEST-012: Blackbox: no gate flow, no continue_on_failure, no Python SDK
- Open. Blackbox suite has 92 cases across 7 categories but doesn't cover these specific scenarios.
