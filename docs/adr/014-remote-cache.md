# ADR 014: Remote Cache

## Status
Proposed

## Context

Sykli's content-addressed cache (`~/.sykli/cache`) is local-only. This creates significant friction for teams:

**Current State:**
```
Alice's laptop          Bob's laptop          Charlie's laptop
┌─────────────┐         ┌─────────────┐       ┌─────────────┐
│ ~/.sykli/   │         │ ~/.sykli/   │       │ ~/.sykli/   │
│   cache/    │         │   cache/    │       │   cache/    │
└─────────────┘         └─────────────┘       └─────────────┘
      ↓                       ↓                     ↓
[builds from scratch]  [builds from scratch]  [builds from scratch]
```

**Pain Points:**
1. **Duplicate work**: 3 devs rebuild the same unchanged dependencies
2. **CI waste**: Every CI run rebuilds from scratch
3. **Onboarding friction**: New dev waits for full build on first clone
4. **Large artifacts**: Rust/C++ builds can be 2GB+ per project

**Goal:**
```
Alice's laptop          Bob's laptop          CI Runner
┌─────────────┐         ┌─────────────┐       ┌─────────────┐
│ local cache │         │ local cache │       │ local cache │
└──────┬──────┘         └──────┬──────┘       └──────┬──────┘
       │                       │                     │
       └───────────────────────┼─────────────────────┘
                               ↓
                    ┌──────────────────┐
                    │   Remote Cache   │
                    │   (S3/GCS/R2)    │
                    └──────────────────┘
```

## Decision

### 1. Layered Cache Architecture

```elixir
# Cache lookup order (first hit wins):
# 1. Local ~/.sykli/cache (instant)
# 2. Remote (S3/GCS/R2) (network)
# 3. Miss → run task → store to both layers

defmodule Sykli.Cache.Backend do
  @callback check(key :: String.t()) :: {:hit, meta} | :miss
  @callback restore(key :: String.t(), dest :: Path.t()) :: :ok | {:error, term()}
  @callback store(key :: String.t(), outputs :: [Path.t()], meta :: map()) :: :ok | {:error, term()}
end

defmodule Sykli.Cache.Local do
  @behaviour Sykli.Cache.Backend
  # Current implementation
end

defmodule Sykli.Cache.S3 do
  @behaviour Sykli.Cache.Backend
  # New: S3-compatible (AWS, Minio, R2, GCS interop)
end
```

### 2. Configuration

```bash
# Environment variables (simple, CI-friendly)
export SYKLI_CACHE_REMOTE=s3://my-bucket/sykli-cache
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...

# Or config file for complex setups
# .sykli/config.exs
config :sykli, :cache,
  layers: [
    {:local, path: "~/.sykli/cache"},
    {:s3, bucket: "my-bucket", prefix: "sykli-cache", region: "us-east-1"}
  ],
  push_to_remote: true,  # Write to remote on cache miss
  pull_from_remote: true # Read from remote on local miss
```

### 3. CLI Integration

```bash
# Check cache status
sykli cache stats
# Local:  1.2GB (234 entries)
# Remote: 8.4GB (1,847 entries)

# Configure remote
sykli cache remote set s3://bucket/prefix

# Warm local cache from remote
sykli cache pull --all
sykli cache pull --task=build  # specific task

# Push local to remote
sykli cache push
```

### 4. S3 Layout

```
s3://bucket/sykli-cache/
├── meta/
│   └── <cache-key>.json     # Task metadata (small, always fetched)
└── blobs/
    └── <sha256>              # Content-addressed outputs (fetched on demand)
```

**Why separate meta from blobs?**
- Meta is tiny (~500 bytes), cheap to list/fetch
- Blobs can be huge (GB), only fetch if needed
- Enables "check without download" for cache hits

### 5. Content-Addressed Deduplication

The current local cache already uses content-addressed storage:
```
~/.sykli/cache/blobs/<sha256-of-content>
```

This means:
- Same file content = same blob, stored once
- If Alice and Bob build the same artifact, remote stores it once
- Cross-project deduplication (shared dependencies)

### 6. Security Considerations

**Read-only for untrusted CI:**
```bash
# CI can read cache but not poison it
SYKLI_CACHE_REMOTE=s3://bucket/cache
SYKLI_CACHE_PUSH=false  # Read-only
```

**Signed URLs (future):**
```elixir
# Generate short-lived signed URLs for blob access
# Prevents credential exposure in CI logs
```

**Cache isolation:**
```bash
# Per-branch cache (prevents main pollution)
SYKLI_CACHE_REMOTE=s3://bucket/cache/${GITHUB_REF_NAME}
```

### 7. Implementation Phases

**Phase 1: S3 Backend (MVP)**
- New `Sykli.Cache.S3` module
- Read from remote on local miss
- Write to remote after task success
- Files: `core/lib/sykli/cache/s3.ex`

**Phase 2: CLI Commands**
- `sykli cache remote set/get`
- `sykli cache push/pull`
- `sykli cache stats --remote`

**Phase 3: GCS Native**
- Direct GCS API (not S3 interop)
- Service account auth
- Files: `core/lib/sykli/cache/gcs.ex`

**Phase 4: Advanced**
- Cache TTL and eviction policies
- Bandwidth limiting for metered connections
- Compression (zstd for blobs)

## Alternatives Considered

### 1. NFS/Shared Filesystem
- **Pros**: Simple, no code changes
- **Cons**: Requires infra, doesn't work for distributed teams

### 2. Redis/Memcached
- **Pros**: Fast, familiar
- **Cons**: Not designed for large blobs, expensive at scale

### 3. HTTP Cache Server
- **Pros**: Simple protocol
- **Cons**: Need to run a server, another thing to maintain

### 4. S3-Compatible (Chosen)
- **Pros**: Ubiquitous, cheap, scales infinitely, works for CI and local
- **Cons**: Network latency (mitigated by local layer)

## Dependencies

- `ex_aws` or `req` for HTTP (already using `req` for K8s)
- AWS credentials (standard env vars work)

## Consequences

**Positive:**
- 10x faster CI (cache warm from previous runs)
- Team cache sharing (build once, use everywhere)
- Smaller delta on clone (only rebuild changed)

**Negative:**
- Network dependency (mitigated by local fallback)
- Cloud costs (S3 is cheap, but not free)
- Credential management (solved by IAM roles in cloud CI)

## Open Questions

1. **Compression**: Zstd for blobs? (likely 2-5x size reduction)
2. **Encryption**: At-rest encryption via S3 SSE, or client-side?
3. **Garbage collection**: Who cleans up old remote entries?
4. **Multi-region**: Replicate cache for geo-distributed teams?
