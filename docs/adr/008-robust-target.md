# ADR-008: Robust Target System

**Status:** Proposed
**Date:** 2025-12-26

---

## Context

The Target abstraction separates WHERE from HOW - a good foundation. But to enable reproducibility, portability, and the Modules ecosystem, Target needs to be more robust.

Current state:
- Target interface is minimal (`run_task/2`)
- Capabilities checked at runtime via behaviour
- No versioning or pinning
- No configuration schema
- No portability features

For Sykli to support reproducible builds and reusable Modules (like CircleCI Orbs), Target must become a first-class, versionable, serializable entity.

---

## Decision

**Evolve Target into a robust, versionable, portable abstraction.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    ROBUST TARGET PRINCIPLES                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   1. Declarative: Target config is data, not just code         │
│   2. Versionable: Targets have versions, can be pinned         │
│   3. Portable: Target configs can be shared across projects    │
│   4. Validated: Configuration errors caught at define-time     │
│   5. Introspectable: Explain what a target provides            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Target Configuration

### Current: Code-Only

```elixir
# Target is just a module with callbacks
{:ok, state} = Sykli.Target.K8s.setup(namespace: "ci")
```

### New: Declarative + Code

```elixir
# Target configuration is explicit, versionable
target = Target.define(:k8s,
  version: "1.0.0",

  # Environment specification
  environment: %{
    namespace: "ci-jobs",
    service_account: "sykli-runner"
  },

  # Default resources for all tasks
  defaults: %{
    resources: %{cpu: "500m", memory: "512Mi"},
    timeout: 300
  },

  # Capabilities this target provides
  capabilities: [:secrets, :storage, :services],

  # Runtime constraints
  constraints: %{
    max_parallel: 10,
    allowed_images: ["ghcr.io/myorg/*", "docker.io/library/*"]
  }
)
```

---

## Target Versioning

Targets are versioned to ensure reproducibility:

```elixir
# Explicit version pinning
target = Target.use(:k8s, version: "~> 1.0")

# Version in lockfile (sykli.lock)
# targets:
#   k8s: "1.0.3"
#   docker: "2.1.0"
```

### Version Resolution

```
┌─────────────────────────────────────────────────────────────────┐
│                    TARGET VERSION RESOLUTION                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   1. Check sykli.lock for pinned version                        │
│   2. If not pinned, resolve from constraint                     │
│   3. Store resolved version in lockfile                         │
│   4. Subsequent runs use locked version                         │
│                                                                 │
│   Same as dependency resolution - reproducibility guaranteed    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Target Schema & Validation

### Type-Safe Configuration

```go
// Go SDK: Compile-time type safety
target := sykli.K8sTarget{
    Namespace: "ci",
    Resources: sykli.K8sResources{
        CPU:    "500m",
        Memory: "512Mi",  // Validated format
    },
    Tolerations: []sykli.K8sToleration{
        {Key: "dedicated", Value: "ci", Effect: "NoSchedule"},
    },
}

// Validation at build time, not runtime
errs := target.Validate()  // []error or nil
```

```elixir
# Elixir SDK: Runtime validation with clear errors
target = Target.K8s.new(
  namespace: "ci",
  resources: %{cpu: "500m", memory: "512Mi"}
)

case Target.validate(target) do
  :ok -> :proceed
  {:error, errors} ->
    # [%{field: "resources.memory", error: "invalid format, use Mi/Gi"}]
end
```

### Schema Definition

```elixir
defmodule Sykli.Target.K8s.Schema do
  use Sykli.Schema

  field :namespace, :string, required: true
  field :service_account, :string, default: "default"

  field :resources, :map do
    field :cpu, :k8s_cpu
    field :memory, :k8s_memory
  end

  field :tolerations, {:list, :toleration}
  field :node_selector, {:map, :string, :string}

  validate :resources, &validate_k8s_resources/1
end
```

---

## Target Capabilities (Enhanced)

### Explicit Declaration

```elixir
defmodule Sykli.Target.K8s do
  use Sykli.Target,
    name: "k8s",
    version: "1.0.0",
    capabilities: [
      :lifecycle,      # setup/teardown
      :secrets,        # resolve_secret
      :storage,        # volumes, artifacts
      :services,       # service containers
      :gpu,            # NVIDIA GPU support
      :spot            # spot/preemptible nodes
    ]
end
```

### Capability Negotiation

```elixir
# At pipeline definition time
pipeline do
  # Task requires GPU
  task "train"
    |> requires(:gpu)
    |> run("python train.py")
end

# At execution time
case Target.check_capabilities(target, [:gpu]) do
  :ok -> execute(task, target)
  {:missing, [:gpu]} ->
    # Error: Target 'local' does not support capability 'gpu'
    # Suggestion: Use k8s target with GPU-enabled node pool
end
```

---

## Target Portability

### Export Configuration

```bash
# Export target configuration
$ sykli target export k8s-production > k8s-prod.target.json
```

```json
{
  "type": "k8s",
  "version": "1.0.3",
  "config": {
    "namespace": "production",
    "service_account": "sykli-prod",
    "resources": {"cpu": "1", "memory": "2Gi"},
    "node_selector": {"pool": "ci-large"}
  },
  "capabilities": ["secrets", "storage", "services", "gpu"],
  "checksum": "sha256:abc123..."
}
```

### Import Configuration

```elixir
# In another project
target = Target.import("./targets/k8s-prod.target.json")

# Or from URL
target = Target.import("https://example.com/targets/k8s-prod.json")
```

---

## Target Introspection

### Explain Mode Integration

```bash
$ sykli explain --target

Target: k8s (v1.0.3)
────────────────────────────────────────
Mode:         in-cluster
Namespace:    ci-jobs
Capabilities: secrets, storage, services, gpu

Defaults:
  CPU:        500m (request) / 2 (limit)
  Memory:     512Mi (request) / 4Gi (limit)
  Timeout:    300s

Constraints:
  Max parallel:   10
  Allowed images: ghcr.io/myorg/*, docker.io/library/*

Tools:
  kubectl:  v1.29.0
  docker:   Docker 24.0.7
```

### Diff Between Targets

```bash
$ sykli target diff local k8s-production

┌────────────────────┬───────────────────┬────────────────────┐
│ Feature            │ local             │ k8s-production     │
├────────────────────┼───────────────────┼────────────────────┤
│ Isolation          │ Container (Docker)│ Pod                │
│ Secrets            │ Environment vars  │ K8s Secrets + Vault│
│ Storage            │ Local filesystem  │ PVC                │
│ GPU                │ No                │ Yes                │
│ Max parallel       │ 4                 │ 50                 │
└────────────────────┴───────────────────┴────────────────────┘
```

---

## Implementation

### Phase 1: Target Schema

Add schema definitions and validation:

```elixir
# core/lib/sykli/target/schema.ex
defmodule Sykli.Target.Schema do
  @callback schema() :: map()
  @callback validate(config :: map()) :: :ok | {:error, [error]}
end
```

### Phase 2: Capability Declaration

Move from runtime checks to explicit declarations:

```elixir
# Before (runtime)
if Sykli.Target.has_capability?(target, :secrets) do

# After (declared)
defmodule MyTarget do
  use Sykli.Target, capabilities: [:secrets, :storage]
end
```

### Phase 3: Portability

Add export/import functionality:

```elixir
# core/lib/sykli/target/portable.ex
defmodule Sykli.Target.Portable do
  def export(target) :: {:ok, json}
  def import(path_or_url) :: {:ok, target} | {:error, reason}
end
```

### Phase 4: Versioning

Add version tracking and lockfile support:

```elixir
# sykli.lock format
%{
  "targets" => %{
    "k8s" => %{
      "version" => "1.0.3",
      "checksum" => "sha256:abc..."
    }
  }
}
```

---

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **Schema + Versioning (chosen)** | Reproducible, shareable | More complexity upfront |
| **Code-only (current)** | Simple | Not portable, hard to version |
| **YAML config files** | Familiar | Not type-safe, separate from code |

---

## Success Criteria

1. Target configuration errors caught at define-time
2. `sykli.lock` pins target versions for reproducibility
3. Targets can be exported/imported between projects
4. `sykli explain --target` shows full configuration
5. Capability requirements validated before execution

---

## Future Work

- Target composition (layered configurations)
- Cost estimation based on target + resources
- Target recommendations based on task requirements