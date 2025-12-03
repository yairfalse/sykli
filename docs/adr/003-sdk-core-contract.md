# ADR-003: SDK → Core Contract

**Status:** Accepted
**Date:** 2024-12-03

---

## Context

Sykli SDKs (Go, Rust, TS) need to communicate task graphs to the Elixir Core. What format and protocol?

## Decision

**JSON over stdout. Simple pipe.**

```
┌──────────────┐         ┌──────────────┐
│   SDK        │  JSON   │    Core      │
│  (sykli.go)  │ ──────► │  (Elixir)    │
│              │ stdout  │              │
└──────────────┘         └──────────────┘
```

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **JSON (chosen)** | Simple, universal, debuggable | No streaming, no types |
| **GraphQL** | Dynamic, lazy eval, optimization | Requires server, complex |
| **Protobuf** | Typed, fast, schema evolution | Compilation step |
| **Direct FFI** | No serialization | Language coupling |

## Why JSON

1. **Machine-generated** — SDK emits it, humans don't edit it
2. **Debuggable** — `go run sykli.go --emit | jq .`
3. **Universal** — Every language has JSON
4. **Stdout-friendly** — No server, no sockets, just pipe
5. **Good enough** — Task graphs are small

## Why Not GraphQL (like Dagger)

Dagger uses GraphQL for dynamic composition and engine-side optimization. Powerful but complex.

Sykli's model is simpler:
- SDK builds complete task graph upfront
- Core executes it
- No dynamic queries needed

If we need GraphQL later (streaming, lazy eval), we can add it.

---

## JSON Schema v1

```json
{
  "version": "1",
  "required_env": ["GITHUB_TOKEN"],
  "tasks": [
    {
      "name": "test",
      "command": "go test ./...",
      "inputs": ["**/*.go", "go.mod", "go.sum"],
      "depends_on": [],
      "timeout": 300,
      "on_failure": "stop"
    },
    {
      "name": "build",
      "command": "go build -o ./app",
      "inputs": ["**/*.go", "go.mod", "go.sum"],
      "depends_on": ["test"],
      "timeout": 600,
      "on_failure": "stop"
    }
  ]
}
```

### Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | string | Yes | Schema version ("1") |
| `required_env` | string[] | No | Env vars to validate before run |
| `tasks` | Task[] | Yes | List of tasks |

### Task Fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | Yes | — | Unique task identifier |
| `command` | string | Yes | — | Shell command to run |
| `inputs` | string[] | No | [] | Glob patterns for cache key |
| `depends_on` | string[] | No | [] | Task names this depends on |
| `timeout` | number | No | 300 | Timeout in seconds |
| `on_failure` | string | No | "stop" | "stop", "continue", or "retry:N" |

---

## Protocol

1. Core detects `sykli.go` (or `.rs`, `.ts`)
2. Core runs: `go run sykli.go --emit`
3. SDK writes JSON to stdout
4. Core parses JSON
5. Core validates `required_env`
6. Core executes tasks

### Error Handling

- **SDK exits non-zero** → Core fails with "SDK error"
- **Invalid JSON** → Core fails with "Parse error"
- **Missing required_env** → Core fails with "Missing: VAR1, VAR2"
- **Unknown task in depends_on** → Core fails with "Unknown task: X"

---

## Future Considerations

If needed later:
- **Streaming**: Add `--stream` flag for long-running output
- **GraphQL**: For dynamic composition (unlikely)
- **Binary format**: For huge task graphs (unlikely)

For v1: JSON over stdout.

---

**Simple. Universal. Good enough.**
