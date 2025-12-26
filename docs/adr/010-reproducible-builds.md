# ADR-010: Reproducible Builds — Content-Addressed CI

**Status:** Proposed
**Date:** 2025-12-26

---

## Context

Most CI systems are not reproducible:
- Same commit → different results
- "Works on my machine" → fails in CI
- Cache invalidation is a guess
- No way to prove two builds are equivalent

Bazel and Nix prove that reproducibility is possible, but they're complex and require all-in commitment.

Sykli can achieve reproducibility progressively, without requiring a complete ecosystem overhaul.

---

## Decision

**Implement content-addressed builds with progressive reproducibility.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    REPRODUCIBILITY LEVELS                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Level 0: No reproducibility (most CI today)                   │
│   Level 1: Lockfile (pin deps, targets, tools)                  │
│   Level 2: Content-addressed (hash inputs → cache key)          │
│   Level 3: Hermetic (network isolation, deterministic)          │
│                                                                 │
│   Sykli starts at Level 1, enables Level 2,                     │
│   optionally enforces Level 3.                                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Level 1: Lockfile

### sykli.lock

```yaml
# sykli.lock - Auto-generated, committed to repo
version: 1

# Pinned targets
targets:
  k8s:
    version: "1.0.3"
    checksum: "sha256:abc123..."
  docker:
    version: "24.0.7"
    checksum: "sha256:def456..."

# Pinned tools (detected at first run)
tools:
  go: "1.21.5"
  node: "20.10.0"
  python: "3.11.7"

# Pinned modules
modules:
  sykli/docker:
    version: "2.1.0"
    checksum: "sha256:ghi789..."
  sykli/go:
    version: "1.3.0"
    checksum: "sha256:jkl012..."

# Base images (pinned by digest)
images:
  golang:1.21:
    digest: "sha256:abc..."
  node:20:
    digest: "sha256:def..."

# Lock metadata
locked_at: "2025-12-26T10:42:00Z"
locked_by: "sykli v0.5.0"
```

### Lock Commands

```bash
# Create or update lockfile
$ sykli lock

Locked:
  Targets:  2 (k8s@1.0.3, docker@24.0.7)
  Tools:    3 (go@1.21.5, node@20.10.0, python@3.11.7)
  Modules:  2 (sykli/docker@2.1.0, sykli/go@1.3.0)
  Images:   2 (golang:1.21, node:20)

Generated sykli.lock

# Verify lock matches current state
$ sykli lock --verify

✓ All versions match lockfile

# Update lockfile
$ sykli lock --update

Updated:
  go: 1.21.5 → 1.22.0
  sykli/docker: 2.1.0 → 2.2.0
```

---

## Level 2: Content-Addressed

### Input Hashing

Every task gets a content hash based on its inputs:

```
┌─────────────────────────────────────────────────────────────────┐
│                    TASK HASH FORMULA                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   task_hash = hash(                                             │
│     command,           # The command to run                     │
│     container_digest,  # Image by digest, not tag               │
│     input_files_hash,  # Hash of declared input files           │
│     env_vars,          # Environment variables (sorted)         │
│     target_config,     # Target configuration hash              │
│     dep_output_hashes  # Hashes of dependency outputs           │
│   )                                                             │
│                                                                 │
│   Same hash = Same result (cacheable)                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Declaring Inputs

```go
s.Task("build").
    Inputs("src/**/*.go", "go.mod", "go.sum").  // Explicit inputs
    Outputs("bin/myapp").                        // Explicit outputs
    Container("golang:1.21").
    Run("go build -o bin/myapp ./cmd/myapp")
```

### Cache Lookup

```
1. Compute task_hash from inputs
2. Check cache: exists(task_hash)?
   - Yes: Skip execution, use cached outputs
   - No: Execute task, store outputs with task_hash
```

### Explain Hash

```bash
$ sykli explain --hash build

Task: build
Hash: sha256:abc123def456...

Components:
  command:         sha256:111... (go build -o bin/myapp ./cmd/myapp)
  container:       sha256:222... (golang:1.21@sha256:...)
  inputs:
    src/**/*.go:   sha256:333... (42 files, 15KB total)
    go.mod:        sha256:444...
    go.sum:        sha256:555...
  env:             sha256:666... (GOOS=linux, GOARCH=amd64)
  target:          sha256:777... (k8s@1.0.3)
  dependencies:    (none)

Cache status: HIT (cached 2 hours ago)
```

### Why Rebuild?

```bash
$ sykli explain --why-rebuild build

Task 'build' will rebuild because:

  Input changed: src/main.go
    - Before: sha256:aaa...
    + After:  sha256:bbb...

  Other inputs unchanged:
    ✓ go.mod
    ✓ go.sum
    ✓ src/pkg/*.go (15 files)
```

---

## Level 3: Hermetic Mode

### Network Isolation

```go
s := sykli.New()

// Enable hermetic mode
s.Hermetic(true)

// All network access blocked during execution
// Dependencies must be pre-fetched
s.Task("build").
    Run("go build ./...")  // Will fail if tries to download
```

### Pre-fetch Phase

```go
// Hermetic builds have explicit pre-fetch
s.Prefetch(
    "go mod download",           // Go dependencies
    "npm ci",                    // Node dependencies
    "pip install -r req.txt",    // Python dependencies
)

// After prefetch, network is blocked
s.Hermetic(true)
```

### Hermetic Enforcement

```
┌─────────────────────────────────────────────────────────────────┐
│                    HERMETIC EXECUTION                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Phase 1: Prefetch (network allowed)                           │
│   ├── Download dependencies                                     │
│   ├── Pull container images                                     │
│   └── Fetch remote resources                                    │
│                                                                 │
│   Phase 2: Build (network blocked)                              │
│   ├── All deps must be local                                    │
│   ├── No external downloads                                     │
│   └── Deterministic execution                                   │
│                                                                 │
│   Violation = Build failure (not silent fallback)               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Content-Addressable Artifact Storage

### Immutable Artifacts

```
# Artifacts stored by content hash
.sykli/
  artifacts/
    sha256:abc123.../        # Content-addressed
      bin/myapp              # The actual artifact
      metadata.json          # Build metadata
```

### Metadata

```json
{
  "task": "build",
  "task_hash": "sha256:abc123...",
  "created_at": "2025-12-26T10:42:00Z",
  "inputs": {
    "src/**/*.go": "sha256:111...",
    "go.mod": "sha256:222..."
  },
  "outputs": {
    "bin/myapp": {
      "hash": "sha256:333...",
      "size": 15234567,
      "mode": 755
    }
  },
  "duration_ms": 4523,
  "target": "k8s@1.0.3"
}
```

### Remote Cache

```elixir
# Configuration
config :sykli, :cache,
  backend: :s3,
  bucket: "sykli-cache",
  region: "us-east-1"

# Or GCS
config :sykli, :cache,
  backend: :gcs,
  bucket: "sykli-cache"

# Or self-hosted
config :sykli, :cache,
  backend: :http,
  url: "https://cache.mycompany.io"
```

---

## Reproducibility Verification

### Build Attestation

```json
{
  "type": "https://sykli.io/attestation/v1",
  "subject": {
    "name": "myapp",
    "digest": "sha256:abc123..."
  },
  "predicate": {
    "builder": "sykli v0.5.0",
    "buildType": "hermetic",
    "invocation": {
      "configSource": {
        "uri": "git+https://github.com/myorg/myapp@refs/heads/main",
        "digest": {"sha1": "abc123..."}
      }
    },
    "materials": [
      {"uri": "pkg:golang/std@1.21.5"},
      {"uri": "pkg:docker/golang@1.21", "digest": "sha256:..."}
    ],
    "reproducible": true
  }
}
```

### Reproducibility Test

```bash
# Run build twice, verify same output
$ sykli build --reproducibility-check

Build 1: sha256:abc123...
Build 2: sha256:abc123...

✓ Reproducible: outputs match
```

---

## Integration with Target

The Target abstraction enables reproducibility:

```
┌─────────────────────────────────────────────────────────────────┐
│                    TARGET = ENVIRONMENT PIN                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Target configuration includes:                                │
│   ├── Container runtime version                                 │
│   ├── Base images (by digest)                                   │
│   ├── Tool versions                                             │
│   ├── Network policy                                            │
│   └── Resource constraints                                      │
│                                                                 │
│   Same Target + Same Inputs = Same Output                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Implementation

### Phase 1: Lockfile

```elixir
# core/lib/sykli/lock.ex
defmodule Sykli.Lock do
  def generate(pipeline) :: {:ok, lockfile}
  def verify(lockfile, current) :: :ok | {:mismatch, diffs}
  def update(lockfile, opts) :: {:ok, new_lockfile}
end
```

### Phase 2: Input Hashing

```elixir
# core/lib/sykli/hash.ex
defmodule Sykli.Hash do
  def task_hash(task, target) :: {:ok, hash}
  def input_hash(patterns, workdir) :: {:ok, hash}
  def explain_hash(task) :: explanation
end
```

### Phase 3: Content Cache

```elixir
# core/lib/sykli/cache.ex
defmodule Sykli.Cache do
  def lookup(task_hash) :: {:ok, artifacts} | :miss
  def store(task_hash, artifacts, metadata) :: :ok
  def explain_rebuild(task) :: reasons
end
```

### Phase 4: Hermetic Mode

```elixir
# core/lib/sykli/hermetic.ex
defmodule Sykli.Hermetic do
  def prefetch(tasks) :: :ok | {:error, reason}
  def enforce_isolation(task) :: :ok | {:violation, attempt}
end
```

---

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **Progressive reproducibility (chosen)** | Gradual adoption, practical | Not as strict as Bazel |
| **Full Bazel-style** | Maximum reproducibility | Requires ecosystem buy-in |
| **No reproducibility** | Simple | Modern expectation |

---

## Success Criteria

1. `sykli.lock` generated and verified on every build
2. Cache hit rate > 80% for unchanged inputs
3. `sykli explain --why-rebuild` answers cache misses
4. Hermetic mode available for strict reproducibility
5. Build attestations generated for compliance

---

## Future Work

- SLSA compliance (Supply-chain Levels for Software Artifacts)
- Sigstore integration for artifact signing
- Distributed cache with content-based deduplication
- Reproducibility dashboard (track drift over time)
- Integration with Nix for ultimate hermeticity
