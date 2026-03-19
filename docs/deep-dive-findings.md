# Sykli Deep Dive Findings — 2026-03-19

Comprehensive analysis from 4 parallel audits: DDD, Architecture, Security, Test Coverage.

## Priority 1: Security (Critical)

### SEC-001: OIDC token requests have no TLS verification
- **File**: `services/oidc_service.ex` lines 72, 138, 198
- **Impact**: MITM can steal cloud credentials on shared runners
- **Fix**: Add `Sykli.HTTP.ssl_opts(url)` to 3 `:httpc.request` calls

### SEC-002: secret_refs file source reads arbitrary paths
- **File**: `executor.ex:882`
- **Impact**: Malicious task graph can read `/etc/shadow`, K8s tokens
- **Fix**: Apply existing `path_within?/2` guard before `File.read`

### SEC-003: Docker mounts allow host path escape
- **File**: `target/local.ex:378`, `runtime/docker.ex:167`
- **Impact**: Task can mount `/` into container
- **Fix**: Apply `path_within?/2` to mount host paths

### SEC-004: Webhook delivery has no SSRF guard
- **File**: `services/notification_service.ex:37`
- **Impact**: Attacker-controlled webhook URL can hit AWS metadata endpoint
- **Fix**: Block private IP ranges, loopback addresses

### SEC-005: Erlang distribution exposed via UDP gossip
- **File**: `daemon.ex:501`, `cluster.ex:50`
- **Impact**: Node identity broadcast on LAN, no TLS on distribution
- **Fix**: Document SYKLI_COOKIE requirement, consider TLS distribution

### SEC-006: SecretMasker misses non-standard secret names
- **File**: `occurrence/enrichment.ex:816`
- **Impact**: Secrets with names like DATABASE_URL appear unmasked
- **Fix**: Collect secrets from task.secret_refs + task.secrets, not just env patterns

### SEC-007: Cache key doesn't cover OIDC-derived runtime secrets
- **File**: `cache.ex:37`, `executor.ex:519`
- **Impact**: Cache hit serves stale output when credentials rotate
- **Fix**: Include secret_refs key names in cache key hash

## Priority 2: Reliability (High)

### REL-001: Executor.Server uses Task.start_link — crash kills GenServer
- **File**: `executor/server.ex:111`
- **Impact**: Crash loses all in-flight state, blocks sync callers forever
- **Fix**: Use `Task.Supervisor.async_nolink`

### REL-002: No graceful shutdown (SIGTERM)
- **File**: `application.ex`
- **Impact**: Docker containers and K8s Jobs orphaned on kill
- **Fix**: Register `:os.set_signal` handler to drain supervisor tree

### REL-003: Concurrent runs race on occurrence.json
- **File**: `occurrence/enrichment.ex:609`
- **Impact**: Two `sykli run` invocations overwrite each other's output
- **Fix**: Use atomic write (tmp + rename) like cache does

### REL-004: S3 cache timeout blocks executor
- **File**: `cache/tiered_repository.ex:43`
- **Impact**: 30s timeout per task when S3 unreachable, 20 tasks = 10min stall
- **Fix**: Async L2 writes, circuit breaker

### REL-005: SCM status calls synchronous per-task, no rate limiting
- **File**: `executor.ex:854`, `github.ex:33`
- **Impact**: 50 tasks = 100 API calls, GitHub rate limit exhaustion
- **Fix**: Async emission via occurrence subscriber, rate limiter

### REL-006: PubSub failure silently swallows occurrence emission
- **File**: `occurrence/pubsub.ex:125`
- **Impact**: PubSub crash = no occurrences emitted, no fallback
- **Fix**: Check broadcast return value, log on error

### REL-007: RunRegistry never evicts
- **File**: `run_registry.ex:99`
- **Impact**: Long-running daemon leaks memory indefinitely
- **Fix**: Add cap and TTL eviction

### REL-008: Telemetry duration units wrong
- **File**: `telemetry.ex:91`
- **Impact**: Logged durations are 1,000,000x too large (native units logged as ms)
- **Fix**: Convert native time to milliseconds

## Priority 3: Architecture (Structural)

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
- HistoryAnalyzer reads RunHistory to feed Occurrence — circular dependency

### ARCH-006: TaskResult means 3 different things
- Executor.TaskResult (6 statuses), RunHistory.TaskResult (3), Coordinator (3 different)
- Lossy translation in sykli.ex:428 discards :errored and :cached

### ARCH-007: Executor.Server reimplements execution without cache/retry/progress
- executor/server.ex has its own run_levels_with_events, divergent from Executor.run
- Dead weight that quietly diverges from production behavior

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

### TEST-001: Occurrence.Enrichment — zero tests for core value prop
### TEST-002: GateService — all 4 approval strategies untested
### TEST-003: S3Signer — AWS Signature V4 correctness untested
### TEST-004: TieredRepository — L1/L2 promotion untested
### TEST-005: OIDCService — credential exchange untested
### TEST-006: Executor.run/3 — no direct unit test
### TEST-007: All 3 SCM providers untested
### TEST-008: ConditionService — branch/tag evaluation untested
### TEST-009: NotificationService — webhook dispatch untested
### TEST-010: RetryService — backoff calculation untested
### TEST-011: Zero property-based testing (StreamData not in deps)
### TEST-012: Blackbox: no gate flow, no continue_on_failure, no Python SDK
