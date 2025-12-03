# ADR-002: Secrets Management

**Status:** Accepted
**Date:** 2024-12-03

---

## Context

CI needs secrets (API keys, deploy tokens, etc.). How should Sykli handle them?

## Decision

**Passthrough model. Sykli stores nothing.**

```
┌─────────────────────────────────────────────────────────┐
│                    SECRETS FLOW                          │
├─────────────────────────────────────────────────────────┤
│                                                         │
│   LOCAL                        GITHUB                   │
│   ┌─────────────┐             ┌─────────────┐          │
│   │ Environment │             │ GH Secrets  │          │
│   │ variables   │             │ → env vars  │          │
│   └──────┬──────┘             └──────┬──────┘          │
│          │                           │                  │
│          └───────────┬───────────────┘                  │
│                      ▼                                  │
│              ┌──────────────┐                           │
│              │    Sykli     │                           │
│              │  (passthru)  │                           │
│              └──────────────┘                           │
│                                                         │
│   Sykli does NOT store secrets.                         │
│   Secrets come from the environment.                    │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## How It Works

### Local execution
```bash
# User sets env vars
export GITHUB_TOKEN=ghp_xxx
export DEPLOY_KEY=xxx

# Sykli inherits environment
sykli
```

### GitHub Actions
```yaml
# .github/workflows/ci.yml
jobs:
  build:
    steps:
      - run: sykli
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          DEPLOY_KEY: ${{ secrets.DEPLOY_KEY }}
```

### In sykli.go (optional validation)
```go
// Declare required secrets — fail fast if missing
sykli.RequireEnv("GITHUB_TOKEN", "DEPLOY_KEY")

// Use in tasks (inherited automatically)
sykli.Run("./deploy.sh")  // has access to DEPLOY_KEY
```

## What Sykli Does

1. **Validates** secrets exist (optional, via `RequireEnv`)
2. **Passes through** environment to tasks
3. **Masks** known secrets in output (future)

## What Sykli Does NOT Do

1. ❌ Store secrets
2. ❌ Encrypt secrets
3. ❌ Manage secret rotation
4. ❌ Provide a secrets UI

## Rationale

- **Simplicity**: No secret management infrastructure
- **Security**: Can't leak what we don't have
- **Compatibility**: Works with any secret source (Vault, 1Password, AWS SM, etc.)
- **Target audience**: Our team first, local + GitHub

## Future Considerations

If needed later:
- Vault integration (fetch at runtime)
- 1Password CLI integration
- AWS Secrets Manager integration

But for now: **passthrough only**.

---

## Implementation

### SDK (Go)
```go
// RequireEnv validates env vars exist before running tasks
func RequireEnv(names ...string) {
    for _, name := range names {
        if os.Getenv(name) == "" {
            // Add to missing list, fail at emit time
        }
    }
}
```

### JSON output
```json
{
  "required_env": ["GITHUB_TOKEN", "DEPLOY_KEY"],
  "tasks": [...]
}
```

### Core (Elixir)
```elixir
# Before execution, validate required env vars
def validate_env(required) do
  missing = Enum.filter(required, fn name ->
    System.get_env(name) == nil
  end)

  case missing do
    [] -> :ok
    vars -> {:error, {:missing_env, vars}}
  end
end
```

---

**No storage. No complexity. Just passthrough.**
