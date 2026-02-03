# SYKLI: AI-Native CI

**CI built for the AI era. Pipelines in your language. Context for AI assistants.**

---

## VISION: CONTEXT, NOT LOGS

Traditional CI outputs logs for humans. Sykli outputs **structured context** for AI.

```
Traditional CI: "here's a log, good luck"
Sykli:          "here's everything you need to understand and fix this"
```

Every feature is a **context generator**:
- Run pipeline → history context (patterns, durations, pass/fail)
- Task fails → error context (code location, recent changes, suggested fix)
- Cache miss → change context (what changed and why)
- Test runs → coverage context (which code is tested by what)

The `.sykli/` directory is the **AI's memory** of your project.

---

## AI-NATIVE TASK SCHEMA

Tasks carry semantic metadata that AI understands:

```json
{
  "name": "test",
  "command": "npm test",
  "after": ["lint"],
  "inputs": ["**/*.ts"],

  "semantic": {
    "covers": ["src/auth/*", "src/api/*"],
    "intent": "unit tests for auth and api modules",
    "criticality": "high"
  },

  "ai_hooks": {
    "on_fail": "analyze",
    "select": "smart"
  },

  "history_hint": {
    "flaky": false,
    "avg_duration_ms": 3200,
    "last_failure": "2024-01-10",
    "failure_rate": 0.02,
    "common_errors": ["timeout", "connection refused"]
  }
}
```

### Three Layers

**Static** (user declares in SDK):
```go
s.Task("test").
  Run("npm test").
  Covers("src/auth/*", "src/api/*").
  Intent("unit tests for auth and api").
  Criticality("high")
```

**Behavioral** (user configures):
```go
s.Task("test").
  OnFail("analyze").   // or "fix", "notify", "ignore"
  Select("smart")      // AI decides if this needs to run
```

**Learned** (Sykli populates from runs):
- Flakiness detection
- Average duration
- Failure patterns
- Common error types

---

## PLANNED AI FEATURES

### Phase 1: Context Generation (Foundation)

**`.sykli/context.json`** - Project understanding
```json
{
  "project": {
    "name": "my-app",
    "languages": ["typescript", "go"],
    "frameworks": ["express", "react"]
  },
  "pipeline": {
    "tasks": 5,
    "avg_duration_ms": 45000,
    "parallelism": 2
  },
  "health": {
    "last_success": "2024-01-15T10:30:00Z",
    "success_rate_7d": 0.94,
    "flaky_tasks": []
  }
}
```

**`.sykli/test-map.json`** - Coverage mapping
```json
{
  "src/auth/login.ts": ["test:auth", "test:e2e"],
  "src/api/users.ts": ["test:api", "test:integration"]
}
```

### Phase 2: CLI Commands

**`sykli explain`** - AI-readable pipeline description
```bash
$ sykli explain --json
{
  "tasks": [...],
  "dependencies": {...},
  "estimated_duration_ms": 45000,
  "critical_path": ["lint", "test", "build"]
}
```

**`sykli plan`** - Dry run based on current diff
```bash
$ sykli plan
Based on changes to src/auth/*, would run:
  ✓ lint (always)
  ✓ test:auth (covers changed files)
  ○ test:api (skipped - no relevant changes)
  ✓ build (depends on test:auth)
```

**`sykli query`** - Natural language queries
```bash
$ sykli query "what tests cover the auth module?"
$ sykli query "why did build fail yesterday?"
$ sykli query "what's flaky?"
```

### Phase 3: AI-Assisted Repair

**`sykli fix`** - Analyze and suggest fixes
```bash
$ sykli fix
Analyzing last failure...

Task: test:auth
Error: expected 200 got 401
Location: src/auth/login.test.ts:42
Recent changes: src/auth/login.ts:15-20

Suggested fix:
  The token validation was changed but tests weren't updated.
  Update line 42 to use the new token format.

Apply fix? [y/n]
```

### Phase 4: Rich Structured Errors

```json
{
  "task": "test",
  "status": "failed",
  "error": {
    "type": "assertion",
    "file": "src/auth/login.test.ts",
    "line": 42,
    "message": "expected 200 got 401",
    "code_context": "expect(response.status).toBe(200)",
    "recent_changes": [
      {"file": "src/auth/login.ts", "lines": "15-20", "author": "alice"}
    ],
    "suggested_fix": "Check token validation in login.ts",
    "similar_failures": ["2024-01-10", "2024-01-03"]
  }
}
```

### Phase 5: MCP Server (Optional Interface)

```json
{
  "mcpServers": {
    "sykli": { "command": "sykli", "args": ["mcp"] }
  }
}
```

Tools exposed:
- `run_pipeline` - Execute with options
- `explain_pipeline` - Get structured description
- `get_failure` - Get last failure with context
- `suggest_tests` - What tests to run for changes
- `get_history` - Recent runs and patterns

---

## THE KILLER WORKFLOW

```
User: "CI is failing, fix it"

Claude Code:
1. Reads .sykli/context.json     → understands the project
2. Runs sykli explain --json     → sees pipeline structure
3. Reads structured error        → knows exactly what failed
4. Sees recent_changes           → knows what caused it
5. Fixes the code                → applies the fix
6. Runs sykli plan               → verifies fix will work
7. Done
```

---

## IMPLEMENTATION ROADMAP

### Milestone 1: Schema & Context (Current)
- [ ] Extend Task struct with `semantic`, `ai_hooks` fields
- [ ] Add `Sykli.Context` module for context.json generation
- [ ] Add `--json` flag to existing commands
- [ ] Update all SDKs with new API (Covers, Intent, Criticality, OnFail)

### Milestone 2: Explain & Plan
- [ ] `sykli explain` command
- [ ] `sykli plan` command with diff analysis
- [ ] Enhanced error output with code context

### Milestone 3: Query & Fix
- [ ] `sykli query` with structured data queries
- [ ] `sykli fix` with failure analysis
- [ ] test-map.json generation from coverage data

### Milestone 4: MCP Integration
- [ ] MCP server implementation
- [ ] Tool definitions for AI assistants
- [ ] Streaming output support

---

## PROJECT STATUS

**What's Implemented:**
- Go SDK (~1000 lines) - full fluent API
- Rust SDK (~1500 lines) - full fluent API
- TypeScript SDK (~1300 lines) - full fluent API with validation
- Elixir SDK - DSL macros
- Parallel execution by dependency level
- Content-addressed caching (SHA256)
- Cycle detection (DFS)
- Matrix build expansion
- Retry with exponential backoff
- Conditional execution
- GitHub status API
- DDD refactoring (services, protocols, typed events)

**Code Stats:**
- ~3500 lines Elixir (core)
- ~3800 lines SDK code (Go + Rust + TypeScript + Elixir)
- 25+ core modules

---

## ARCHITECTURE OVERVIEW

```
sykli.go  ──run──▶  JSON task graph  ──▶  parallel execution
   SDK                  stdout              Elixir engine
                           │
                           ▼
                    .sykli/context.json  ◄── AI reads this
```

### Core Modules

| Module | Purpose |
|--------|---------|
| `Detector` | Finds SDK file, runs `--emit` |
| `Graph` | JSON parsing, topological sort, cycle detection |
| `Executor` | Parallel execution by level |
| `Cache` | Content-addressed caching (repository pattern) |
| `Services.*` | CacheService, RetryService, ConditionService, etc. |
| `Target.*` | Local (Docker/shell), K8s (Jobs) |
| `Events.*` | Typed event structs for observability |
| `Context` | (planned) AI context generation |
| `Explain` | (planned) Pipeline description |
| `Plan` | (planned) Dry run with diff analysis |

### File Locations

| What | Where |
|------|-------|
| CLI entry | `core/lib/sykli/cli.ex` |
| Graph parsing | `core/lib/sykli/graph.ex` |
| Executor | `core/lib/sykli/executor.ex` |
| Services | `core/lib/sykli/services/` |
| Cache | `core/lib/sykli/cache/` |
| Target protocols | `core/lib/sykli/target/protocols/` |
| Events | `core/lib/sykli/events/` |
| Go SDK | `sdk/go/sykli.go` |
| Rust SDK | `sdk/rust/src/lib.rs` |
| TypeScript SDK | `sdk/typescript/src/index.ts` |

---

## SDK API (Current + Planned)

### Go

```go
package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
    s := sykli.New()

    // Current API
    s.Task("test").
        Run("go test ./...").
        Inputs("**/*.go").
        After("lint")

    // Planned: Semantic metadata
    s.Task("test").
        Run("go test ./...").
        Inputs("**/*.go").
        Covers("src/auth/*", "src/api/*").
        Intent("unit tests for auth and api").
        Criticality("high").
        OnFail("analyze")

    s.Emit()
}
```

### TypeScript

```typescript
import { Pipeline } from 'sykli';

const p = new Pipeline();

// Current API
p.task('test')
  .run('npm test')
  .inputs('**/*.ts')
  .after('lint');

// Planned: Semantic metadata
p.task('test')
  .run('npm test')
  .inputs('**/*.ts')
  .covers('src/auth/*', 'src/api/*')
  .intent('unit tests for auth and api')
  .criticality('high')
  .onFail('analyze');

p.emit();
```

---

## VERIFICATION CHECKLIST

Before every commit:

```bash
cd core

# Format
mix format

# Tests
mix test

# Build escript
mix escript.build

# Test the binary
./sykli --help
```

---

## AGENT INSTRUCTIONS

When working on this codebase:

1. **AI-native first** - Every feature should generate context for AI
2. **Structured output** - Use `--json` flags, typed structs, not strings
3. **SDK consistency** - Update all four SDKs together
4. **Read first** - Understand existing patterns before changing
5. **Run tests** - `cd core && mix test`

The goal: make Sykli the CI that AI assistants understand natively.
