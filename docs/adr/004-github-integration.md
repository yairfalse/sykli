# ADR-004: GitHub Integration

**Status:** Accepted
**Date:** 2024-12-03

---

## Context

Sykli needs to report build status to GitHub so PRs show pass/fail.

## Decision

**Per-task commit statuses via GitHub Status API.**

Each task gets its own status:
```
ci/sykli/test     ✓ success
ci/sykli/lint     ✓ success
ci/sykli/build    ✗ failure
```

---

## Why Commit Status API (not Check Runs)

| | Commit Status API | Check Runs API |
|---|------------------|----------------|
| **Auth** | Any token (PAT, GITHUB_TOKEN) | GitHub App only |
| **Setup** | Just env vars | Register app, install |
| **Features** | Basic status | Rich annotations |

For v1: Commit Status API is simpler. Can upgrade to Check Runs later.

---

## Flow

```
┌─────────────────────────────────────────────────────────┐
│                  PER-TASK STATUS                         │
├─────────────────────────────────────────────────────────┤
│                                                         │
│   Task "test" starts                                    │
│   → POST /repos/:owner/:repo/statuses/:sha              │
│     { state: "pending", context: "ci/sykli/test" }      │
│                                                         │
│   Task "test" passes                                    │
│   → POST /repos/:owner/:repo/statuses/:sha              │
│     { state: "success", context: "ci/sykli/test" }      │
│                                                         │
│   Task "build" fails                                    │
│   → POST /repos/:owner/:repo/statuses/:sha              │
│     { state: "failure", context: "ci/sykli/build" }     │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## Required Environment

```bash
# Auto-set by GitHub Actions
GITHUB_TOKEN=ghp_xxx          # or ${{ github.token }}
GITHUB_REPOSITORY=owner/repo
GITHUB_SHA=abc123

# Sykli detects these and enables GitHub integration automatically
```

---

## SDK Interface

```go
// Explicit enable
sykli.GitHub().PerTaskStatus()

// With custom prefix (default: "ci/sykli")
sykli.GitHub().PerTaskStatus("build/myapp")
// → build/myapp/test, build/myapp/lint, etc.

// Full example
func main() {
    sykli.GitHub().PerTaskStatus()

    sykli.Test()
    sykli.Lint()
    sykli.Build("./app")

    sykli.MustEmit()
}
```

---

## JSON Schema

```json
{
  "version": "1",
  "github": {
    "enabled": true,
    "per_task_status": true,
    "context_prefix": "ci/sykli"
  },
  "required_env": ["GITHUB_TOKEN"],
  "tasks": [
    {
      "name": "test",
      "command": "go test ./..."
    }
  ]
}
```

### GitHub Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | false | Enable GitHub integration |
| `per_task_status` | bool | true | Status per task (vs overall) |
| `context_prefix` | string | "ci/sykli" | Prefix for status context |

---

## Core Implementation

```elixir
defmodule Sykli.GitHub do
  @api_url "https://api.github.com"

  def enabled? do
    System.get_env("GITHUB_TOKEN") != nil and
    System.get_env("GITHUB_REPOSITORY") != nil and
    System.get_env("GITHUB_SHA") != nil
  end

  def update_status(task_name, state, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "ci/sykli")
    context = "#{prefix}/#{task_name}"

    repo = System.get_env("GITHUB_REPOSITORY")
    sha = System.get_env("GITHUB_SHA")
    token = System.get_env("GITHUB_TOKEN")

    body = %{
      state: state,
      context: context,
      description: description_for(state, task_name)
    }

    :post
    |> Finch.build(
      "#{@api_url}/repos/#{repo}/statuses/#{sha}",
      [
        {"Authorization", "token #{token}"},
        {"Accept", "application/vnd.github+json"},
        {"Content-Type", "application/json"}
      ],
      Jason.encode!(body)
    )
    |> Finch.request(Sykli.Finch)
  end

  defp description_for("pending", task), do: "Running #{task}..."
  defp description_for("success", task), do: "#{task} passed"
  defp description_for("failure", task), do: "#{task} failed"
  defp description_for("error", task), do: "#{task} errored"
end
```

---

## Executor Integration

```elixir
defmodule Sykli.Executor do
  def run_single(task, workdir, opts) do
    github_enabled = Keyword.get(opts, :github, false)
    prefix = Keyword.get(opts, :github_prefix, "ci/sykli")

    # Mark pending
    if github_enabled do
      Sykli.GitHub.update_status(task.name, "pending", prefix: prefix)
    end

    # Run task
    result = execute_command(task.command, workdir)

    # Update status
    if github_enabled do
      state = if result == :ok, do: "success", else: "failure"
      Sykli.GitHub.update_status(task.name, state, prefix: prefix)
    end

    result
  end
end
```

---

## GitHub Actions Example

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Sykli
        run: |
          # Install sykli binary (TBD)

      - name: Run CI
        run: sykli
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          # GITHUB_REPOSITORY and GITHUB_SHA are auto-set
```

---

## Auto-detection

If GitHub env vars are present, Sykli can auto-enable:

```go
// Auto-detect mode
func main() {
    sykli.AutoDetectIntegrations() // enables GitHub if env vars present

    sykli.Test()
    sykli.MustEmit()
}
```

Or explicit opt-in only (safer):
```go
func main() {
    sykli.GitHub().PerTaskStatus() // explicit

    sykli.Test()
    sykli.MustEmit()
}
```

**Decision:** Start with explicit opt-in. Auto-detect later.

---

## Future Enhancements

- **Check Runs API** — richer annotations, log streaming
- **PR comments** — summary comment with results
- **target_url** — link to detailed logs
- **Re-run support** — via Check Runs API

---

**Per-task visibility. Simple API. Works with GITHUB_TOKEN.**
