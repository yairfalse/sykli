# ADR 017: Task Placement and Scheduling

## Status
Proposed

## Context

Sykli runs on a spectrum from "3 laptops" to "Kubernetes cluster". The same pipeline should work everywhere, but tasks need to run in the right place:

- GPU training → server with GPU
- Release build → beefy builder
- Unit tests → local laptop (fast feedback)
- Integration tests → server with stable DB access

**Current state:** User manually picks target (`--target=local`, `--target=k8s`, `--mesh`). No automatic placement.

**Goal:** Tasks declare requirements. Sykli picks the best node.

## Decision

### 1. Task Requirements (SDK)

Tasks declare what they NEED, not where they run:

```rust
// Rust SDK
p.task("train")
    .run("python train.py")
    .requires_gpu(1)
    .requires_memory("32Gi")
    .requires_label("arch", "amd64");

p.task("build")
    .run("cargo build --release")
    .requires_cpu(8)
    .prefers_remote();  // Hint: run on server if available

p.task("test")
    .run("cargo test")
    .prefers_local();   // Hint: fast feedback loop
```

```go
// Go SDK
s.Task("train").
    Run("python train.py").
    RequiresGPU(1).
    RequiresMemory("32Gi")

s.Task("test").
    Run("go test ./...").
    PrefersLocal()
```

```typescript
// TypeScript SDK
p.task('train')
    .run('python train.py')
    .requiresGpu(1)
    .requiresMemory('32Gi');

p.task('test')
    .run('npm test')
    .prefersLocal();
```

### 2. Node Capabilities

Each node advertises what it HAS:

```elixir
# Auto-detected on daemon start
%NodeCapabilities{
  cpu_cores: 64,
  memory_gb: 128,
  gpu: 2,
  gpu_type: "nvidia-a100",
  labels: %{
    "arch" => "amd64",
    "os" => "linux",
    "zone" => "us-east-1a"
  },
  features: [:docker, :k8s, :nix]
}
```

**Detection:**
```elixir
defmodule Sykli.Capabilities do
  def detect do
    %{
      cpu_cores: System.schedulers_online(),
      memory_gb: detect_memory(),
      gpu: detect_gpu(),
      docker: has_docker?(),
      labels: read_labels()  # From .sykli/node.exs or env
    }
  end
end
```

### 3. Scheduler

The scheduler matches requirements to capabilities:

```elixir
defmodule Sykli.Scheduler do
  @doc """
  Select best node for a task.

  Returns {:ok, node} or {:error, :no_suitable_node}
  """
  def schedule(task, available_nodes) do
    # Filter: nodes that CAN run this task
    capable = Enum.filter(available_nodes, &can_run?(task, &1))

    case capable do
      [] -> {:error, :no_suitable_node}
      nodes ->
        # Rank: pick best node
        best = rank_nodes(task, nodes) |> List.first()
        {:ok, best}
    end
  end

  defp can_run?(task, node) do
    # Hard requirements - must match
    satisfies_gpu?(task, node) and
    satisfies_memory?(task, node) and
    satisfies_labels?(task, node)
  end

  defp rank_nodes(task, nodes) do
    # Soft preferences - influence ranking
    Enum.sort_by(nodes, fn node ->
      score = 0
      score = if task.prefers_local and node == :local, do: score + 100, else: score
      score = if task.prefers_remote and node != :local, do: score + 100, else: score
      score = score + available_capacity_score(node)
      -score  # Higher is better, sort descending
    end)
  end
end
```

### 4. Placement Policies

Three modes for different team needs:

```elixir
# .sykli/config.exs

# SOLO: Everything local (default for new users)
config :sykli, :placement, :local_only

# MESH: Distribute to connected nodes
config :sykli, :placement, :mesh
config :sykli, :mesh_nodes, [:"server1@10.0.0.1", :"server2@10.0.0.2"]

# HYBRID: Local for quick tasks, remote for heavy
config :sykli, :placement, :hybrid
config :sykli, :hybrid_rules, [
  # Tasks with GPU requirement → remote
  {:requires_gpu, :remote},
  # Tasks > 30s typical runtime → remote
  {:slow_task, :remote},
  # Everything else → local
  {:default, :local}
]
```

### 5. The Small Team Setup (2 servers + 3 laptops)

```
                    ┌─────────────────────────────────────┐
                    │           Mesh Network              │
                    │  (mDNS discovery on office LAN)     │
                    └─────────────────────────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
        ▼                             ▼                             ▼
┌───────────────┐             ┌───────────────┐             ┌───────────────┐
│ Alice laptop  │             │ Bob laptop    │             │ Charlie laptop│
│ ───────────── │             │ ───────────── │             │ ───────────── │
│ 8 cores       │             │ 8 cores       │             │ 16 cores      │
│ 16GB RAM      │             │ 32GB RAM      │             │ 32GB RAM      │
│ no GPU        │             │ no GPU        │             │ no GPU        │
│               │             │               │             │               │
│ prefers_local │             │ prefers_local │             │ prefers_local │
│ tasks only    │             │ tasks only    │             │ tasks only    │
└───────────────┘             └───────────────┘             └───────────────┘
                                      │
                    ┌─────────────────┴─────────────────┐
                    │                                   │
                    ▼                                   ▼
            ┌───────────────┐                   ┌───────────────┐
            │ Server 1      │                   │ Server 2      │
            │ ───────────── │                   │ ───────────── │
            │ 64 cores      │                   │ 32 cores      │
            │ 256GB RAM     │                   │ 64GB RAM      │
            │ 2x A100 GPU   │                   │ no GPU        │
            │               │                   │               │
            │ Labels:       │                   │ Labels:       │
            │   gpu: true   │                   │   builder     │
            │   ml: true    │                   │   ci: true    │
            └───────────────┘                   └───────────────┘
```

**Pipeline behavior:**

```rust
let p = Pipeline::new();

// Runs on laptop (fast feedback)
p.task("lint").run("cargo fmt --check").prefers_local();
p.task("test").run("cargo test").prefers_local();

// Runs on Server 2 (beefy builder)
p.task("build")
    .run("cargo build --release")
    .requires_cpu(16)
    .prefers_remote();

// Runs on Server 1 (has GPU)
p.task("train")
    .run("python train.py")
    .requires_gpu(1);

// Runs on Server 2 (stable DB)
p.task("integration")
    .run("./integration-tests.sh")
    .requires_label("ci", "true");
```

**What happens when Alice runs `sykli`:**

```
$ sykli run

Mesh: 5 nodes connected
  local (Alice laptop)  - 8 cores, 16GB
  bob@10.0.0.12        - 8 cores, 32GB
  charlie@10.0.0.13    - 16 cores, 32GB
  server1@10.0.0.100   - 64 cores, 256GB, 2x GPU
  server2@10.0.0.101   - 32 cores, 64GB

── Scheduling ──
  lint        → local (prefers_local)
  test        → local (prefers_local)
  build       → server2@10.0.0.101 (requires 16 cores)
  train       → server1@10.0.0.100 (requires GPU)
  integration → server2@10.0.0.101 (requires label ci=true)

── Level 0 (parallel) ──
▶ lint        local           cargo fmt --check
▶ test        local           cargo test
✓ lint        42ms
✓ test        3.2s

── Level 1 ──
▶ build       server2         cargo build --release
✓ build       45s

── Level 2 (parallel) ──
▶ train       server1         python train.py
▶ integration server2         ./integration-tests.sh
✓ integration 12s
✓ train       2m15s

✓ All tasks completed
```

### 6. Cache Sharing in Mesh

When tasks run on remote nodes, cache should be shared:

```elixir
defmodule Sykli.Cache.Mesh do
  @doc """
  Check cache across all mesh nodes.
  Returns {:hit, node, key} or :miss
  """
  def check(key) do
    # 1. Check local first (instant)
    case Local.check(key) do
      {:hit, _} = hit -> {:hit, :local, hit}
      :miss ->
        # 2. Ask mesh nodes in parallel
        Mesh.available_nodes()
        |> Task.async_stream(&check_remote(&1, key))
        |> Enum.find_value(fn
          {:ok, {:hit, node, meta}} -> {:hit, node, meta}
          _ -> nil
        end)
        |> case do
          nil -> :miss
          hit -> hit
        end
    end
  end

  @doc """
  Fetch cached result from remote node.
  """
  def fetch(key, from_node) do
    # Stream blobs from remote node to local cache
    :rpc.call(from_node, Local, :stream_blobs, [key])
    |> Enum.each(&Local.store_blob/1)
  end
end
```

**No S3 required.** Cache lives on the mesh.

### 7. Failure Handling

```elixir
# If scheduled node fails, retry on another capable node
case Scheduler.schedule(task, nodes) do
  {:ok, node} ->
    case Mesh.dispatch_task(task, node, opts) do
      :ok -> :ok
      {:error, :node_disconnected} ->
        # Remove failed node, reschedule
        remaining = List.delete(nodes, node)
        schedule_and_run(task, remaining, opts)
      {:error, reason} ->
        {:error, reason}
    end
  {:error, :no_suitable_node} ->
    {:error, {:no_node_for_requirements, task.requirements}}
end
```

### 8. SDK Changes

**New JSON fields:**
```json
{
  "name": "train",
  "command": "python train.py",
  "requirements": {
    "gpu": 1,
    "memory": "32Gi",
    "cpu": 8,
    "labels": {"arch": "amd64"}
  },
  "placement": {
    "preference": "remote"
  }
}
```

**SDK methods:**
```
.requiresGpu(n)
.requiresMemory(size)
.requiresCpu(cores)
.requiresLabel(key, value)
.requiresFeature(name)        // :docker, :k8s, :nix
.prefersLocal()
.prefersRemote()
.mustRunOn(nodePattern)       // "server*" or specific node
```

## Consequences

**Positive:**
- Same pipeline works everywhere (laptop → server → k8s)
- Small teams need no cloud infrastructure
- Automatic optimal placement
- Cache sharing without S3

**Negative:**
- More complex scheduler logic
- Node capability detection adds startup time
- Network partitions need handling

## Implementation Phases

1. **Phase 1: Requirements parsing** - SDK changes, JSON schema
2. **Phase 2: Capability detection** - Auto-detect CPU/memory/GPU
3. **Phase 3: Scheduler** - Match requirements to nodes
4. **Phase 4: Mesh cache** - Share cache over RPC
5. **Phase 5: Failure handling** - Retry on alternate nodes

## Related ADRs

- **ADR-013 (Mesh Swarm)**: Node discovery and connection
- **ADR-014 (Remote Cache)**: S3 backend (optional, for enterprise)
- **ADR-015 (K8s Source)**: K8s as another "node type"
