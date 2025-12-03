# ADR-001: Sykli Meta Design

**Status:** Draft
**Date:** 2024-12-03

---

## Core Philosophy

**Local first, remote when you have to.**

Sykli runs locally by default. Same code, same behavior. Remote execution is opt-in for when you need more compute or CI integration.

---

## 1. SDK → Core Contract

### What we know
- SDK emits JSON task graph
- Core parses and executes

### Open questions
- **Metadata**: Should JSON include project info? (name, version, language)
- **Environment**: How are env vars passed? In JSON or inherited?
- **Secrets**: How do secrets flow? (env vars? vault integration?)

### Current JSON schema
```json
{
  "tasks": [
    {
      "name": "test",
      "command": "go test ./...",
      "inputs": ["**/*.go"],
      "depends_on": [],
      "outputs": [],           // artifacts?
      "on_failure": "stop"     // or "continue"?
    }
  ]
}
```

### Questions to resolve
- [ ] Should SDK know about remote execution? Or is that Core's job?
- [ ] Streaming output vs buffered?
- [ ] Task timeout in JSON or global config?

---

## 2. Execution Model

### Decision
```
┌─────────────────────────────────────────────────────┐
│                    EXECUTION                         │
├─────────────────────────────────────────────────────┤
│                                                     │
│   LOCAL (default)          REMOTE (opt-in)          │
│   ┌─────────────┐         ┌─────────────┐          │
│   │ Same machine│         │ Worker pool │          │
│   │ No network  │         │ Distributed │          │
│   │ Fast        │         │ Scalable    │          │
│   └─────────────┘         └─────────────┘          │
│                                                     │
│   CONTAINERS: Optional                              │
│   - Not required by default                         │
│   - Opt-in per task: container: "golang:1.21"       │
│   - Useful for reproducibility, not mandatory       │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### Local execution
- Default mode
- Uses system tools (go, cargo, npm)
- Fast feedback loop

### Remote execution
- Opt-in: `sykli --remote` or task-level
- When: CI, heavy builds, parallelism beyond local cores
- How: TBD (workers? queue? cloud functions?)

### Containers
- **Not required** — runs on host by default
- **Opt-in per task**:
  ```go
  sykli.Task("build").Container("golang:1.21").Run("go build")
  ```
- Useful for: reproducibility, isolation, specific toolchains

---

## 3. Caching

### Decision
```
LOCAL execution  →  LOCAL cache (~/.sykli/cache)
REMOTE execution →  SHARED cache (TBD: S3? GCS? custom?)
```

### Content-addressed caching
```
hash(inputs) → cache key
if cache hit → skip task, restore outputs
if cache miss → run task, store outputs
```

### Local cache
- Location: `~/.sykli/cache/`
- Key: `sha256(task_name + inputs_hash)`
- Value: outputs + exit code + logs

### Remote cache (future)
- Shared across CI runs
- Options: S3, GCS, custom backend
- Same content-addressing

---

## 4. Language Detection

### Options

**Option A: Explicit only**
- User must create `sykli.go` / `sykli.rs`
- More control, less magic

**Option B: Auto-detect + generate**
- Detect `go.mod` → suggest/generate `sykli.go`
- `sykli init` creates starter config
- Magic but helpful for onboarding

**Option C: Hybrid**
- Auto-detect for `sykli.Check()` (run standard checks)
- Explicit for custom tasks

### Current leaning
Undecided. Start with explicit, maybe add `sykli init` later.

---

## 5. Outputs & Integrations

### Artifacts
- User-defined via SDK:
  ```go
  sykli.Task("build").Output("./dist/app")
  ```
- Storage: local by default, configurable destination

### GitHub Integration (first plugin)
- Commit status updates
- PR checks
- Triggered via:
  ```go
  sykli.GitHub().Status()  // update commit status
  ```

### Plugin model
- Integrations as plugins (GitHub, Slack, S3, etc.)
- Core is minimal, plugins add features
- Plugin interface TBD

---

## 6. Failure Handling

### Decision: User-defined and modular

```go
// Per-task failure handling
sykli.Task("lint").OnFailure(sykli.Continue)  // don't block other tasks
sykli.Task("test").OnFailure(sykli.Stop)      // stop everything (default)
sykli.Task("deploy").OnFailure(sykli.Retry(3)) // retry 3 times

// Global default
sykli.Config().OnFailure(sykli.Stop)
```

### Failure modes
| Mode | Behavior |
|------|----------|
| `Stop` | Halt execution, fail the build (default) |
| `Continue` | Mark failed, continue independent tasks |
| `Retry(n)` | Retry n times before failing |
| `Ignore` | Pretend it passed (dangerous, explicit) |

### Implementation
- `on_failure` field in JSON task
- Core respects it during execution
- Default: `stop`

---

## Open Questions

1. **SDK ↔ Core versioning**: How do we handle SDK/Core version mismatch?
2. **Remote workers**: Build our own? Use existing (Buildkite, etc.)?
3. **Secrets**: Env vars? Vault? Something else?
4. **Monorepo support**: Detect changed packages, run only affected?
5. **Watch mode**: `sykli watch` — re-run on file changes?

---

## Next Steps

1. Finalize JSON schema (task contract)
2. Implement failure handling in Core
3. Add output/artifact support
4. Build GitHub status plugin
5. Design remote execution architecture

---

**Local first. Remote when needed. Your language. Your CI.**
