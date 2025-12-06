# ADR-007: CDEvents for Event Output

**Status:** Proposed
**Date:** 2024-12-06

---

## Context

Sykli needs to emit events during execution (task started, task finished, etc.). These events power:
1. Terminal output (human-readable)
2. JSON output (machine-readable)
3. Future: TUI, web dashboard, integrations

What event format should we use?

## Decision

**Adopt CDEvents as the event schema. Emit CloudEvents envelope.**

```
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   Elixir     │ Events  │   Output     │         │  Consumers   │
│   Core       │ ──────► │   Adapter    │ ──────► │              │
│              │         │              │         │  • Terminal  │
└──────────────┘         └──────────────┘         │  • --json    │
                                                  │  • TUI       │
                                                  │  • Webhooks  │
                                                  └──────────────┘
```

## What is CDEvents

[CDEvents](https://cdevents.dev/) is a CNCF specification for CI/CD events. Built on CloudEvents.

**Why it matters:**
- Standard vocabulary for CI/CD
- Interoperability with Tekton, Jenkins, Keptn, etc.
- OpenTelemetry CI/CD SIG is bridging CDEvents → OTEL traces

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **CDEvents (chosen)** | Standard, interoperable, future-proof | Slightly verbose |
| **Custom events** | Simple, minimal | Reinventing the wheel |
| **OpenTelemetry only** | Great for tracing | Not designed for CI/CD events |
| **GitHub Actions format** | Familiar | Proprietary, limited |

## CDEvents Mapping

### Core Events

| Sykli Concept | CDEvent Type |
|---------------|--------------|
| Pipeline starts | `dev.cdevents.pipelinerun.started` |
| Pipeline finishes | `dev.cdevents.pipelinerun.finished` |
| Task starts | `dev.cdevents.taskrun.started` |
| Task finishes | `dev.cdevents.taskrun.finished` |

### Custom Extensions (sykli namespace)

| Sykli Concept | Event Type |
|---------------|------------|
| Task output line | `dev.sykli.taskrun.output` |
| Cache hit | `dev.sykli.cache.hit` |
| Cache miss | `dev.sykli.cache.miss` |
| Level started | `dev.sykli.level.started` |

---

## Event Schema

### CloudEvents Envelope

All events use CloudEvents envelope:

```json
{
  "specversion": "1.0",
  "id": "evt-abc123",
  "source": "sykli/local",
  "type": "dev.cdevents.taskrun.started",
  "time": "2024-12-06T10:30:00Z",
  "datacontenttype": "application/json",
  "data": { ... }
}
```

### taskrun.started

```json
{
  "specversion": "1.0",
  "type": "dev.cdevents.taskrun.started",
  "source": "sykli/local",
  "id": "tr-build-001",
  "time": "2024-12-06T10:30:00Z",
  "data": {
    "context": {
      "pipelineRun": { "id": "pr-001" }
    },
    "subject": {
      "id": "build",
      "type": "taskRun",
      "content": {
        "taskName": "build",
        "pipelineName": "sykli.go"
      }
    },
    "customData": {
      "command": "go build -o ./app",
      "container": "golang:1.21",
      "level": 1
    }
  }
}
```

### taskrun.finished

```json
{
  "specversion": "1.0",
  "type": "dev.cdevents.taskrun.finished",
  "source": "sykli/local",
  "id": "tr-build-002",
  "time": "2024-12-06T10:30:05Z",
  "data": {
    "context": {
      "pipelineRun": { "id": "pr-001" }
    },
    "subject": {
      "id": "build",
      "type": "taskRun",
      "content": {
        "taskName": "build",
        "outcome": "success"
      }
    },
    "customData": {
      "duration_ms": 5000,
      "cached": false,
      "exit_code": 0
    }
  }
}
```

### taskrun.output (sykli extension)

```json
{
  "specversion": "1.0",
  "type": "dev.sykli.taskrun.output",
  "source": "sykli/local",
  "id": "out-001",
  "time": "2024-12-06T10:30:02Z",
  "data": {
    "taskName": "build",
    "stream": "stdout",
    "line": "compiling main.go..."
  }
}
```

### cache.hit (sykli extension)

```json
{
  "specversion": "1.0",
  "type": "dev.sykli.cache.hit",
  "source": "sykli/local",
  "id": "cache-001",
  "time": "2024-12-06T10:30:00Z",
  "data": {
    "taskName": "test",
    "cacheKey": "abc123def456",
    "savedDuration_ms": 12000
  }
}
```

---

## Output Modes

### Default (Terminal)

Human-readable, translated from events:

```
── Level with 2 task(s) ──
▶ lint  go vet ./...
▶ test  go test ./...
✓ lint (0.3s)
✓ test (2.1s)

── Level with 1 task(s) ──
▶ build  go build -o ./app
✓ build (5.0s)

✓ Pipeline complete (7.4s)
```

### --json (NDJSON)

Newline-delimited JSON events:

```bash
sykli --json
```

```json
{"specversion":"1.0","type":"dev.cdevents.pipelinerun.started",...}
{"specversion":"1.0","type":"dev.cdevents.taskrun.started","data":{"subject":{"id":"lint"}},...}
{"specversion":"1.0","type":"dev.cdevents.taskrun.started","data":{"subject":{"id":"test"}},...}
{"specversion":"1.0","type":"dev.sykli.taskrun.output","data":{"taskName":"test","line":"PASS"},...}
{"specversion":"1.0","type":"dev.cdevents.taskrun.finished","data":{"subject":{"content":{"outcome":"success"}}},...}
...
```

### --quiet

Minimal output:

```
✓ lint ✓ test ✓ build
```

### Future: --webhook URL

POST events to webhook endpoint.

---

## Implementation

### Elixir Core Changes

```elixir
defmodule Sykli.Events do
  @moduledoc "CDEvents emission"

  def task_started(task, pipeline_id) do
    %{
      specversion: "1.0",
      type: "dev.cdevents.taskrun.started",
      source: source(),
      id: generate_id("tr"),
      time: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: %{
        context: %{pipelineRun: %{id: pipeline_id}},
        subject: %{
          id: task.name,
          type: "taskRun",
          content: %{taskName: task.name}
        },
        customData: %{
          command: task.command,
          level: task.level
        }
      }
    }
  end

  defp source do
    case System.get_env("CI") do
      nil -> "sykli/local"
      _ -> "sykli/ci"
    end
  end
end
```

### Output Adapter

```elixir
defmodule Sykli.Output do
  def emit(event, mode) do
    case mode do
      :terminal -> Terminal.render(event)
      :json -> IO.puts(Jason.encode!(event))
      :quiet -> Quiet.render(event)
    end
  end
end
```

---

## Integration Points

### Kulta (Progressive Delivery)

Kulta can subscribe to `pipelinerun.finished` to trigger deployments:

```
Sykli ──pipelinerun.finished──► Kulta ──starts canary──► K8s
```

### Tapio (Observability)

Tapio can correlate deployment events with system metrics:

```
Kulta ──deployment.started──► Tapio ──watches──► eBPF metrics
```

### External Systems

Any CDEvents-compatible system can consume sykli events:
- Tekton
- Keptn
- Custom dashboards

---

## Migration Path

1. **Phase 1**: Emit events internally (Elixir structs)
2. **Phase 2**: Add `--json` flag with CDEvents format
3. **Phase 3**: Add webhook support
4. **Phase 4**: OpenTelemetry trace correlation

---

## References

- [CDEvents Spec](https://github.com/cdevents/spec)
- [CloudEvents Spec](https://cloudevents.io/)
- [OpenTelemetry CI/CD SIG](https://opentelemetry.io/blog/2025/otel-cicd-sig/)

---

**Standard events. Universal integration. Future-proof.**
