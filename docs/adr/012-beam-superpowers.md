# ADR-012: BEAM Superpowers

**Status:** Proposed
**Date:** 2025-12-26

---

## Context

"Why Elixir?" is the first question every Go/Rust developer asks about Sykli.

The answer isn't "because functional programming is elegant" or "because we like pattern matching." The answer is: **BEAM gives us capabilities that are impossible or extremely difficult in other runtimes.**

This ADR documents the three BEAM superpowers that make Sykli fundamentally different from every other CI tool.

---

## The Three Superpowers

```
┌─────────────────────────────────────────────────────────────────┐
│                    BEAM SUPERPOWERS                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. DISTRIBUTED BY DEFAULT                                      │
│      Your laptop ←→ CI runner ←→ Teammate's machine              │
│      Same mesh. Real-time coordination.                          │
│                                                                  │
│   2. OBSERVABLE WITHOUT INSTRUMENTATION                          │
│      No APM agents. No sidecars. No overhead.                    │
│      The runtime IS the observability layer.                     │
│                                                                  │
│   3. HOT CODE PATHS                                              │
│      Push config to running targets.                             │
│      No restart. No downtime. No state loss.                     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Superpower 1: Distributed by Default

### The Problem with Other CI Tools

```
┌─────────────────────────────────────────────────────────────────┐
│                    TRADITIONAL CI                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Developer Machine              CI Server                       │
│   ┌──────────────┐               ┌──────────────┐               │
│   │   sykli      │               │   sykli      │               │
│   │   (lonely)   │               │   (lonely)   │               │
│   └──────────────┘               └──────────────┘               │
│                                                                  │
│   No connection. No coordination. No shared state.               │
│   Each instance is an island.                                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### The BEAM Way

```
┌─────────────────────────────────────────────────────────────────┐
│                    SYKLI MESH                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐   │
│   │   sykli      │◄───►│   sykli      │◄───►│   sykli      │   │
│   │   (laptop)   │     │   (CI)       │     │   (teammate) │   │
│   └──────────────┘     └──────────────┘     └──────────────┘   │
│          │                    │                    │            │
│          └────────────────────┴────────────────────┘            │
│                         Erlang Distribution                      │
│                                                                  │
│   Automatic discovery. Real-time events. Shared cache.           │
│   Every node sees every node.                                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### What This Enables

#### Remote Task Observation

```elixir
# On your laptop: watch CI runner in real-time
$ sykli observe ci-runner-7

Observing node: ci-runner-7@192.168.1.50
────────────────────────────────────────────────────────
Task: build-frontend
  Status: running (2m 14s)
  Memory: 1.2GB
  CPU: 78%

  Live output:
  > Compiling src/components/Button.tsx
  > Compiling src/components/Modal.tsx
  > ...

[Press 'a' to attach shell, 's' to stream logs, 'k' to kill]
```

#### Distributed Cache

```elixir
# Cache is shared across the mesh
# Build on laptop, cache hit on CI

# Laptop builds:
$ sykli run build
  ✓ Compiling src/... (cached to mesh)

# CI runs 5 minutes later:
$ sykli run build
  ✓ Compiling src/... (cache hit from laptop@192.168.1.42)
```

#### Peer-to-Peer Artifact Sharing

```elixir
# Teammate built the exact same image?
# Pull from their machine, not the registry.

$ sykli run deploy
  Image: myapp:abc123
  Source: teammate@192.168.1.55 (local mesh)
  Speed: 2.3 GB/s (vs 50 MB/s from registry)
```

### Implementation

```elixir
defmodule Sykli.Mesh do
  @moduledoc """
  Erlang Distribution with automatic discovery.
  """

  use GenServer

  # Automatic node discovery via mDNS or explicit config
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    # Connect to known nodes
    for node <- opts[:seeds] || [] do
      Node.connect(node)
    end

    # Start mDNS discovery
    if opts[:discovery] == :mdns do
      Sykli.Mesh.Discovery.start()
    end

    # Subscribe to node events
    :net_kernel.monitor_nodes(true)

    {:ok, %{nodes: Node.list()}}
  end

  def handle_info({:nodeup, node}, state) do
    Logger.info("Node joined mesh", node: node)
    # Sync state with new node
    Sykli.Cache.sync_with(node)
    {:noreply, %{state | nodes: Node.list()}}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.warning("Node left mesh", node: node)
    {:noreply, %{state | nodes: Node.list()}}
  end
end
```

```elixir
defmodule Sykli.Mesh.TaskObserver do
  @moduledoc """
  Observe tasks running on any node in the mesh.
  """

  def observe(node, task_id) do
    # Subscribe to task events from remote node
    :rpc.call(node, Sykli.Task.Events, :subscribe, [task_id, self()])

    # Stream events to local terminal
    stream_events()
  end

  defp stream_events do
    receive do
      {:task_output, line} ->
        IO.puts(line)
        stream_events()

      {:task_status, status} ->
        render_status(status)
        stream_events()

      {:task_complete, result} ->
        render_result(result)
    end
  end
end
```

---

## Superpower 2: Observable Without Instrumentation

### The Problem with Other Runtimes

```
┌─────────────────────────────────────────────────────────────────┐
│                    TRADITIONAL OBSERVABILITY                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Your App                                                       │
│   ┌──────────────┐                                              │
│   │              │                                              │
│   │  + APM Agent │ ← Adds 5-15% overhead                        │
│   │  + Metrics   │ ← Custom instrumentation                     │
│   │  + Tracing   │ ← OpenTelemetry SDK                          │
│   │  + Logging   │ ← Structured logging library                 │
│   │              │                                              │
│   └──────────────┘                                              │
│          │                                                       │
│          ▼                                                       │
│   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐   │
│   │  Datadog     │     │  Jaeger      │     │  Loki        │   │
│   └──────────────┘     └──────────────┘     └──────────────┘   │
│                                                                  │
│   External infrastructure. Significant overhead.                 │
│   Observability is bolted on.                                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### The BEAM Way

```
┌─────────────────────────────────────────────────────────────────┐
│                    BEAM OBSERVABILITY                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Sykli                                                          │
│   ┌──────────────────────────────────────────────────┐          │
│   │                                                   │          │
│   │   Every process is introspectable                 │          │
│   │   - Message queue length                          │          │
│   │   - Memory usage                                  │          │
│   │   - Current function                              │          │
│   │   - Stack trace                                   │          │
│   │   - Linked processes                              │          │
│   │   - Garbage collection stats                      │          │
│   │                                                   │          │
│   │   No agents. No SDKs. No overhead.               │          │
│   │   This is how BEAM works.                         │          │
│   │                                                   │          │
│   └──────────────────────────────────────────────────┘          │
│                                                                  │
│   Observability is built in. Zero configuration.                 │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### What This Enables

#### Live Process Inspection

```elixir
$ sykli debug

Sykli Debug Console
────────────────────────────────────────────────────────

Processes (247 total):
  PID           NAME                  MEMORY    QUEUE    STATUS
  <0.1523.0>    Task:build-frontend   124 MB    0        running
  <0.1524.0>    Task:test-unit        89 MB     3        waiting
  <0.1525.0>    Git.Worker            12 MB     0        running
  <0.1526.0>    Cache.ETS             2.1 GB    0        idle

[Enter PID to inspect, 't' for trace, 'm' for memory]

> <0.1523.0>

Process <0.1523.0> (Task:build-frontend)
────────────────────────────────────────────────────────
  Status:          running
  Current:         Sykli.Task.Executor.run_step/2
  Memory:          124 MB (heap: 98 MB, stack: 26 MB)
  Message queue:   0
  Reductions:      12,847,293
  Links:           [<0.1520.0>, <0.1521.0>]

  State:
    %Sykli.Task{
      name: "build-frontend",
      step: 3,
      started_at: ~U[2025-12-26 10:42:00Z],
      container: "node:20-alpine",
      ...
    }
```

#### Zero-Overhead Tracing

```elixir
# Trace function calls without code changes
$ sykli trace Sykli.Target.K8s.apply --limit 100

Tracing Sykli.Target.K8s.apply/2 (max 100 calls)
────────────────────────────────────────────────────────

10:42:01.234  apply(%Task{name: "deploy"}, %K8s{...})
              → {:ok, %Result{duration: 1.2s}}

10:42:03.456  apply(%Task{name: "test"}, %K8s{...})
              → {:ok, %Result{duration: 0.8s}}

10:42:05.678  apply(%Task{name: "build"}, %K8s{...})
              → {:error, :pod_failed}
              Stack: [
                Sykli.Target.K8s.apply/2 (k8s.ex:142)
                Sykli.Task.Executor.run/1 (executor.ex:87)
                ...
              ]
```

#### Memory Analysis

```elixir
$ sykli memory

Memory Analysis
────────────────────────────────────────────────────────

Total:     2.8 GB
  Processes: 1.2 GB (42%)
  ETS:       1.4 GB (50%)
  Binary:    0.2 GB (8%)

Top Processes by Memory:
  1. Cache.ETS         1.4 GB  (artifact cache)
  2. Task:build-all    312 MB  (active task)
  3. Git.Worker        89 MB   (repo clone)

Top ETS Tables:
  1. :sykli_artifacts  1.2 GB  12,847 entries
  2. :sykli_cache      200 MB  3,421 entries

[Suggestion: Consider pruning artifacts older than 7 days]
```

### Implementation

```elixir
defmodule Sykli.Debug do
  @moduledoc """
  BEAM-native debugging without external tools.
  """

  def list_processes do
    for pid <- Process.list() do
      info = Process.info(pid, [
        :registered_name,
        :memory,
        :message_queue_len,
        :status,
        :current_function
      ])

      %{
        pid: pid,
        name: info[:registered_name],
        memory: info[:memory],
        queue: info[:message_queue_len],
        status: info[:status],
        function: info[:current_function]
      }
    end
    |> Enum.sort_by(& &1.memory, :desc)
  end

  def inspect_process(pid) do
    info = Process.info(pid, :all)
    state = :sys.get_state(pid)

    %{
      info: info,
      state: state,
      stack: Process.info(pid, :current_stacktrace)
    }
  end

  def trace(module, function, arity, opts \\ []) do
    limit = opts[:limit] || 100

    :dbg.tracer()
    :dbg.p(:all, :call)
    :dbg.tpl(module, function, arity, [])

    # Auto-stop after limit
    spawn(fn ->
      Process.sleep(opts[:timeout] || 60_000)
      :dbg.stop()
    end)
  end
end
```

---

## Superpower 3: Hot Code Paths

### The Problem with Other CI Tools

```
┌─────────────────────────────────────────────────────────────────┐
│                    TRADITIONAL CONFIG UPDATE                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. Edit config file                                            │
│   2. Commit and push                                             │
│   3. CI picks up change                                          │
│   4. Restart CI runner                     ← State lost!         │
│   5. Re-initialize everything              ← Slow!               │
│   6. Cache warmed up again                 ← Minutes wasted!     │
│   7. Ready to use new config                                     │
│                                                                  │
│   Time: 5-10 minutes. State: Lost.                               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### The BEAM Way

```
┌─────────────────────────────────────────────────────────────────┐
│                    BEAM HOT CONFIG                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. Edit config                                                 │
│   2. Push to running node:                                       │
│      $ sykli config push                                         │
│   3. Config applied immediately            ← No restart!         │
│   4. State preserved                       ← Cache intact!       │
│   5. Ready                                 ← Instant!            │
│                                                                  │
│   Time: <1 second. State: Preserved.                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### What This Enables

#### Live Config Updates

```bash
# Add a new target while tasks are running
$ sykli config push --target lambda

Pushing config to mesh...
  ✓ laptop@local          (config updated)
  ✓ ci-runner-1@cloud     (config updated)
  ✓ ci-runner-2@cloud     (config updated)

Lambda target now available. No restart needed.
Running tasks unaffected.
```

#### Dynamic Scaling

```elixir
# Scale workers without restart
$ sykli scale workers 10

Scaling workers: 4 → 10
  ✓ Spawned 6 new workers
  ✓ Work redistributed

Active tasks redistributed:
  - Task:build-1    worker-5 → worker-7
  - Task:build-2    worker-3 → worker-9

No tasks interrupted.
```

#### Rolling Target Updates

```elixir
# Update target implementation without stopping builds
$ sykli upgrade target k8s

Upgrading K8s target...
  ✓ New module compiled
  ✓ Running tasks: 3 (will complete with old code)
  ✓ New tasks: use new code

Upgrade complete. Zero downtime.
```

### Implementation

```elixir
defmodule Sykli.Config.Hot do
  @moduledoc """
  Hot configuration updates across the mesh.
  """

  use GenServer

  def push(config) do
    # Validate config first
    with {:ok, validated} <- Sykli.Config.validate(config) do
      # Push to all nodes in mesh
      results =
        for node <- [node() | Node.list()] do
          result = :rpc.call(node, __MODULE__, :apply_config, [validated])
          {node, result}
        end

      {:ok, results}
    end
  end

  def apply_config(config) do
    # Update application env
    for {key, value} <- config do
      Application.put_env(:sykli, key, value)
    end

    # Notify running processes
    Phoenix.PubSub.broadcast(Sykli.PubSub, "config", {:config_updated, config})

    :ok
  end
end
```

```elixir
defmodule Sykli.Target.Registry do
  @moduledoc """
  Dynamic target registration with hot updates.
  """

  use GenServer

  def register(name, module) do
    GenServer.call(__MODULE__, {:register, name, module})
  end

  def upgrade(name, new_module) do
    GenServer.call(__MODULE__, {:upgrade, name, new_module})
  end

  def handle_call({:upgrade, name, new_module}, _from, state) do
    # Compile new module
    {:module, ^new_module} = Code.ensure_compiled(new_module)

    # Update registry - new tasks use new module
    # Running tasks continue with old module (process isolation)
    new_state = Map.put(state.targets, name, new_module)

    Logger.info("Target upgraded", target: name, module: new_module)

    {:reply, :ok, %{state | targets: new_state}}
  end
end
```

---

## The Compound Effect

These superpowers combine:

```
┌─────────────────────────────────────────────────────────────────┐
│                    SUPERPOWERS COMBINED                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Scenario: CI is slow, need to debug                            │
│                                                                  │
│   Traditional:                                                   │
│   1. SSH into CI runner                                          │
│   2. Add print statements                                        │
│   3. Commit, push, wait for CI                                   │
│   4. Read logs, guess, repeat                                    │
│   5. Time: hours                                                 │
│                                                                  │
│   Sykli:                                                         │
│   1. From laptop: sykli observe ci-runner-7                      │
│   2. Attach to running process                                   │
│   3. Live trace function calls                                   │
│   4. Push config fix: sykli config push                          │
│   5. Time: minutes                                               │
│                                                                  │
│   Distributed × Observable × Hot = Superpowered debugging        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Why Not Other Languages?

| Capability | Go | Rust | BEAM |
|------------|-----|------|------|
| Native distribution | ✗ (needs gRPC) | ✗ (needs tokio + custom) | ✓ (built-in) |
| Process introspection | ✗ (needs pprof) | ✗ (needs external) | ✓ (built-in) |
| Hot code reload | ✗ | ✗ | ✓ (built-in) |
| Crash isolation | ✗ (goroutine panic = crash) | ✗ (panic = crash) | ✓ (process crash = restart) |
| Location transparency | ✗ | ✗ | ✓ (same API local/remote) |

**These aren't library features. They're runtime features.**

You can approximate them in other languages with enough infrastructure:
- gRPC + Consul for distribution
- Prometheus + pprof for observability
- Blue-green deploys for "hot" updates

But with BEAM, you get them for free. They're how the runtime works.

---

## Constraints

### Network Requirements

```yaml
# Mesh requires connectivity
mesh:
  # mDNS for local discovery (same network)
  discovery: mdns

  # Or explicit seeds for cross-network
  seeds:
    - ci-runner-1@10.0.1.50
    - ci-runner-2@10.0.1.51

  # Erlang distribution port
  port: 4369  # epmd
  port_range: 9000-9100  # node communication
```

### Security

```yaml
# Mesh is authenticated via cookie
mesh:
  # Shared secret (generate with: mix phx.gen.secret)
  cookie: "super_secret_cookie_here"

  # Or certificate-based auth
  ssl:
    cert: /etc/sykli/mesh.crt
    key: /etc/sykli/mesh.key
```

### Not a Silver Bullet

- Mesh adds latency (~1-5ms per hop)
- Observability has memory overhead for tracing
- Hot updates require careful state migration

---

## Mesh Feature Levels

The superpowers manifest as concrete features, prioritized by impact and demo-ability:

```
┌─────────────────────────────────────────────────────────────────┐
│                    MESH FEATURE LEVELS                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Level 1: CACHE SHARING               ← Ship first ($$$)       │
│   Level 2: LIVE OBSERVATION            ← Ship second (DX wow)   │
│   Level 3: DISTRIBUTED EXECUTION       ← Later (architecture)   │
│   Level 4: TEAM AWARENESS              ← Later (polish)         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Level 1: Cache Sharing (Priority: P0)

**The pitch:** "I built this. You get a cache hit."

Your laptop ↔ CI ↔ teammate. Same content-addressed cache. Build once, hit everywhere.

```bash
# Terminal 1: Alice builds
$ sykli run build
  ✓ build-frontend (23s)
  ✓ build-backend (45s)
  Cached to mesh.

# Terminal 2: Bob builds (5 seconds later)
$ sykli run build
  ⚡ build-frontend (cache hit from alice@192.168.1.42)
  ⚡ build-backend (cache hit from alice@192.168.1.42)
  Done in 0.3s
```

**Why first:**
- Saves hours per day across a team
- Easy to measure (build times, CI costs)
- Engineering managers approve budget ("cut CI costs 60%")

**Implementation:**
- Content-addressed blobs (already in `Sykli.Cache`)
- Cache metadata sync via Erlang distribution
- Bloom filter for "do you have this key?" queries

### Level 2: Live Observation (Priority: P0)

**The pitch:** "Watch CI from your couch."

CI is running? See it live from your terminal. Not logs after the fact - live stdout, resource usage, which step it's on. Attach if you need to.

```bash
$ sykli observe ci-runner-3

Observing: ci-runner-3@10.0.1.50
────────────────────────────────────────────────────────
Task: test-integration
  ████████████░░░░░░░░  Step 7/12  (2m 14s)
  Memory: 1.2GB  CPU: 78%

Live output:
  > Running test_user_signup... passed
  > Running test_checkout...

[Press 'a' to attach, 'k' to kill, 'q' to quit]
```

**Why second:**
- Developers tell their friends ("holy shit" moment)
- Demo-able in 30 seconds
- No other CI does this

**Implementation:**
- PubSub for task events
- `:rpc.call/4` for remote process inspection
- TUI with `ratatouille` or `owl`

### Level 3: Distributed Execution (Priority: P1)

**The pitch:** "Your laptop is slow? Offload heavy tasks to a beefy CI runner."

Same pipeline, different compute. Your laptop stays cool, CI runner does the work.

```bash
$ sykli run build --on ci-runner-large

Offloading to ci-runner-large@10.0.1.50...
  ✓ build-frontend (12s on 32-core)
  ✓ build-backend (8s on 32-core)
  Artifacts synced back.

Done in 22s (would be 4m locally).
```

**Why later:**
- Needs Levels 1+2 working first
- More complex scheduling
- Security implications (code runs remotely)

**Implementation:**
- Task serialization and transfer
- Artifact streaming back
- Resource-based scheduling

### Level 4: Team Awareness (Priority: P2)

**The pitch:** "Who's running what right now?"

Not a dashboard you check - presence in the mesh itself.

```bash
$ sykli mesh status

Sykli Mesh (7 nodes)
────────────────────────────────────────────────────────
  alice@laptop      idle
  bob@laptop        build-frontend (2m)
  ci-runner-1       test-unit (45s) ← triggered by alice
  ci-runner-2       idle
  ci-runner-3       deploy-staging (1m)

Recent:
  10:42  alice pushed feature-x
  10:41  bob cache hit from alice (build-frontend)
  10:38  ci-runner-1 completed test-all ✓

Queue:
  1. test-integration (waiting for ci-runner-1)
```

**Why last:**
- Nice-to-have, not need-to-have
- Requires good UX design
- Builds on all other levels

**Implementation:**
- Presence tracking via PubSub
- Event log aggregation
- Real-time mesh TUI

---

## Feature Comparison

```
┌─────────────────────────────────────────────────────────────────┐
│                    NO ONE ELSE HAS THIS                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│                    GitHub   CircleCI   Dagger   Sykli            │
│   ─────────────────────────────────────────────────────────      │
│   Shared cache       ✗        ✗         ~        ✓               │
│   Live observation   ✗        ✗         ✗        ✓               │
│   Distributed exec   ✗        ✗         ✗        ✓               │
│   Team awareness     ✗        ✗         ✗        ✓               │
│                                                                  │
│   The mesh makes CI feel like a shared space, not a black box.   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Implementation Phases

### Phase 1: Local Mesh + Cache (Levels 1+2)

- mDNS discovery on local network
- Shared cache between laptop and teammates
- Basic remote observation
- Live task streaming

### Phase 2: Cloud Mesh (Sykli Cloud)

- Explicit node discovery for CI runners
- Secure cookie + TLS
- Full distributed cache with persistence
- Cross-region cache replication

### Phase 3: Distributed Execution (Level 3)

- Task offloading to remote nodes
- Resource-based scheduling
- Artifact streaming

### Phase 4: Team Awareness (Level 4)

- Mesh presence and status
- Event aggregation
- Full TUI dashboard

---

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **BEAM native (chosen)** | All superpowers built-in | Learning curve for non-Elixir devs |
| **Go + gRPC** | Familiar to most | Bolt-on distribution, no introspection |
| **Rust + custom mesh** | Performance | Massive implementation effort |
| **Node.js + Redis** | Large ecosystem | No native distribution or introspection |

---

## Success Criteria

1. `sykli observe <node>` works across network
2. Distributed cache provides 10x speedup for repeated builds
3. Config updates apply in <1 second, no restart
4. Zero external APM tools required for debugging
5. Crash in one task doesn't affect other tasks

---

## Pipelines as Real Code

The BEAM superpowers are about the runtime. But there's another advantage: **pipelines are Elixir code, not YAML.**

This isn't just syntax preference. It unlocks capabilities YAML can't have.

### Composition and Reuse

Extract common patterns into functions and modules. Share them across projects.

```elixir
# shared/lib/ci/common.ex
defmodule CI.Common do
  @moduledoc "Shared CI patterns across all projects"

  def docker_build(image, dockerfile \\ "Dockerfile") do
    task "build-#{image}"
    |> container("docker:24-dind")
    |> run("docker build -t #{image} -f #{dockerfile} .")
    |> outputs(["#{image}.tar"])
  end

  def go_test(packages \\ "./...") do
    task "test"
    |> container("golang:1.22")
    |> run("go test -v #{packages}")
    |> inputs(["**/*.go", "go.mod", "go.sum"])
  end

  def deploy_to_k8s(env, image) do
    task "deploy-#{env}"
    |> container("bitnami/kubectl:latest")
    |> run("""
      kubectl set image deployment/app app=#{image}
      kubectl rollout status deployment/app
    """)
    |> requires(:k8s)
  end
end

# Project A: sykli.exs
import CI.Common

pipeline do
  docker_build("myapp:latest")
  |> then(deploy_to_k8s("staging", "myapp:latest"))
end

# Project B: sykli.exs (same patterns, different config)
import CI.Common

pipeline do
  docker_build("other-app:latest", "Dockerfile.prod")
  |> then(go_test())
  |> then(deploy_to_k8s("production", "other-app:latest"))
end
```

**YAML can't do this.** You get copy-paste or complex templating (Jsonnet, Helm). With Elixir, it's just functions.

### Conditional Logic

Normal Elixir control flow. Not a foreign DSL.

```elixir
pipeline do
  # Branch on environment
  env = System.get_env("CI_ENVIRONMENT", "dev")

  build_task = task "build"
    |> container("node:20")
    |> run("npm run build")

  # Conditional deployment
  if env == "production" do
    build_task
    |> then(task "deploy-prod" |> run("./deploy.sh prod"))
  else
    build_task
    |> then(task "deploy-staging" |> run("./deploy.sh staging"))
  end
end

# Or use pattern matching
defp deploy_target do
  case System.get_env("BRANCH") do
    "main" -> "production"
    "develop" -> "staging"
    _ -> "preview"
  end
end

# Or use the Delta module for changed files
pipeline do
  {:ok, affected} = Sykli.Delta.affected_tasks(tasks, from: "main")

  if "backend" in affected do
    task "test-backend" |> run("go test ./...")
  end

  if "frontend" in affected do
    task "test-frontend" |> run("npm test")
  end
end
```

**YAML conditionals** are string interpolation hacks (`if: ${{ github.ref == 'refs/heads/main' }}`). Elixir conditionals are just... conditionals.

### Testing Pipelines

Unit test your pipeline definitions. YAML can't do this.

```elixir
# test/pipeline_test.exs
defmodule PipelineTest do
  use ExUnit.Case

  test "production pipeline includes security scan" do
    pipeline = MyApp.Pipeline.build(env: "production")

    task_names = Enum.map(pipeline.tasks, & &1.name)

    assert "security-scan" in task_names
    assert "deploy-prod" in task_names
  end

  test "staging pipeline skips security scan" do
    pipeline = MyApp.Pipeline.build(env: "staging")

    task_names = Enum.map(pipeline.tasks, & &1.name)

    refute "security-scan" in task_names
    assert "deploy-staging" in task_names
  end

  test "build task has correct inputs" do
    pipeline = MyApp.Pipeline.build(env: "dev")
    build = Enum.find(pipeline.tasks, & &1.name == "build")

    assert "src/**/*.ts" in build.inputs
    assert "package.json" in build.inputs
  end

  test "deploy requires k8s capability" do
    pipeline = MyApp.Pipeline.build(env: "production")
    deploy = Enum.find(pipeline.tasks, & &1.name == "deploy-prod")

    assert :k8s in deploy.requires
  end
end
```

Run `mix test` before pushing. Catch pipeline bugs before they hit CI.

### TDD Your CI: Simulate with Mocks

This is the real killer. Not just "test your pipeline" — **test your pipeline with simulated failures**.

```elixir
defmodule PipelineSimulationTest do
  use ExUnit.Case

  test "deploy only runs when build succeeds" do
    pipeline = MyApp.Pipeline.build()

    # Simulate build failure
    result = Sykli.Simulate.run(pipeline,
      mock: %{"build" => {:error, "compile failed"}}
    )

    refute "deploy" in result.executed
    assert "build" in result.failed
  end

  test "handles flaky network gracefully" do
    pipeline = MyApp.Pipeline.build()

    # Simulate network timeout on first two attempts
    result = Sykli.Simulate.run(pipeline,
      mock: %{
        "push-image" => [
          {:error, :timeout},
          {:error, :timeout},
          {:ok, "pushed"}
        ]
      }
    )

    assert result.retry_count["push-image"] == 2
    assert "push-image" in result.executed
  end

  test "cache miss triggers full rebuild" do
    pipeline = MyApp.Pipeline.build()

    result = Sykli.Simulate.run(pipeline,
      cache: :miss  # Simulate no cache
    )

    assert "build" in result.executed
    assert result.tasks["build"].duration > 0
  end

  test "cache hit skips build" do
    pipeline = MyApp.Pipeline.build()

    result = Sykli.Simulate.run(pipeline,
      cache: :hit  # Simulate cache hit
    )

    refute "build" in result.executed
    assert "build" in result.cached
  end

  test "service container timeout is handled" do
    pipeline = MyApp.Pipeline.build()

    result = Sykli.Simulate.run(pipeline,
      mock: %{
        "test-integration" => {:error, {:service_timeout, "postgres"}}
      }
    )

    assert result.tasks["test-integration"].error == {:service_timeout, "postgres"}
    # Verify cleanup happened
    assert result.cleanup_ran
  end

  test "rollback triggers on deploy failure" do
    pipeline = MyApp.Pipeline.build(env: "production")

    result = Sykli.Simulate.run(pipeline,
      mock: %{"deploy-prod" => {:error, "pod crashlooping"}}
    )

    assert "deploy-prod" in result.failed
    assert "rollback" in result.executed
  end
end
```

**Nobody can do this.**

- You can't mock a GitHub Actions workflow
- You can't simulate failures in CircleCI
- You can't test retry logic in GitLab CI

You just push and pray.

With Sykli: **TDD your CI.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    TDD FOR CI                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. Write the test first                                        │
│      "What should happen when deploy fails?"                     │
│      "What if the cache misses?"                                 │
│      "What if postgres times out?"                               │
│                                                                  │
│   2. Run the test                                                │
│      $ mix test test/pipeline_simulation_test.exs                │
│      (runs in seconds, no actual containers)                     │
│                                                                  │
│   3. Make it pass                                                │
│      Add retry logic, rollback handling, timeout config          │
│                                                                  │
│   4. Push with confidence                                        │
│      You've already tested the failure modes                     │
│                                                                  │
│   Traditional CI: "It works until it doesn't"                    │
│   Sykli: "I've tested what happens when it doesn't"              │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

This isn't incremental. This is a **different relationship with CI entirely.**

### Simulate Implementation

```elixir
defmodule Sykli.Simulate do
  @moduledoc """
  Dry-run pipeline execution with mocked task results.
  """

  defstruct [
    :executed,
    :failed,
    :cached,
    :skipped,
    :tasks,
    :retry_count,
    :cleanup_ran
  ]

  def run(pipeline, opts \\ []) do
    mocks = opts[:mock] || %{}
    cache_behavior = opts[:cache] || :normal

    state = %__MODULE__{
      executed: [],
      failed: [],
      cached: [],
      skipped: [],
      tasks: %{},
      retry_count: %{},
      cleanup_ran: false
    }

    # Execute pipeline with mocked results
    Enum.reduce(pipeline.tasks, state, fn task, acc ->
      execute_simulated(task, acc, mocks, cache_behavior)
    end)
  end

  defp execute_simulated(task, state, mocks, cache_behavior) do
    # Check cache first
    if should_cache_hit?(task, cache_behavior) do
      %{state | cached: [task.name | state.cached]}
    else
      # Check for mock result
      case get_mock_result(mocks, task.name, state.retry_count) do
        {:ok, _} ->
          %{state |
            executed: [task.name | state.executed],
            tasks: Map.put(state.tasks, task.name, %{duration: 0, error: nil})
          }

        {:error, reason} ->
          %{state |
            failed: [task.name | state.failed],
            tasks: Map.put(state.tasks, task.name, %{duration: 0, error: reason})
          }

        :retry ->
          new_count = Map.update(state.retry_count, task.name, 1, & &1 + 1)
          execute_simulated(task, %{state | retry_count: new_count}, mocks, cache_behavior)
      end
    end
  end

  defp get_mock_result(mocks, task_name, retry_count) do
    case Map.get(mocks, task_name) do
      nil -> {:ok, :default}
      list when is_list(list) ->
        # Sequential results for retries
        index = Map.get(retry_count, task_name, 0)
        Enum.at(list, index, List.last(list))
      result -> result
    end
  end

  defp should_cache_hit?(task, :hit), do: task.cacheable != false
  defp should_cache_hit?(_task, :miss), do: false
  defp should_cache_hit?(_task, :normal), do: false
end
```

### Error Locality

When something fails, the error points at **your** code.

```elixir
# Bad: YAML error
# Error: yaml: line 47: mapping values are not allowed here
# (Which line? Which file? What did I do wrong?)

# Good: Elixir error
** (ArgumentError) task "build" is missing required field :command
    sykli.exs:12: MyApp.Pipeline.build/1
    lib/sykli/executor.ex:45: Sykli.Executor.validate/1

# Even better: compile-time error
** (CompileError) sykli.exs:12: undefined function containr/1
    (did you mean container/1?)
```

Stack traces point at your pipeline file, your line number, your function. Not Sykli internals.

### IDE Experience

Full language server support. This is the other half of "your language."

```elixir
# In VS Code with ElixirLS:

task "build"
|> container("node:20")
|> run("npm run build")
|> out|  # ← Autocomplete: outputs, output_dir, ...

# Hover over `container`:
# @spec container(Task.t(), String.t()) :: Task.t()
# Sets the container image for this task.

# Go-to-definition on `CI.Common.docker_build`:
# → jumps to shared/lib/ci/common.ex:8

# Find all references to `deploy_to_k8s`:
# → shows all projects using this function
```

**YAML gives you:** syntax highlighting (maybe), schema validation (if configured).
**Elixir gives you:** autocomplete, type hints, go-to-definition, find references, inline docs, refactoring tools.

### The Real Test

```
┌─────────────────────────────────────────────────────────────────┐
│                    YAML vs ELIXIR                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│                              YAML        Elixir                  │
│   ───────────────────────────────────────────────────────        │
│   Composition/reuse          copy-paste  functions               │
│   Conditional logic          string hacks if/case/cond          │
│   Test pipeline definitions  no          yes                     │
│   Error points to your code  no          yes                     │
│   IDE autocomplete           limited     full                    │
│   Type checking              no          dialyzer               │
│   Refactoring tools          no          yes                     │
│                                                                  │
│   "Write in your language" isn't about syntax preference.        │
│   It's about the entire toolchain working for you.               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## The Philosophy

> **The runtime is the platform.**
>
> Other CI tools are applications that happen to be distributed.
> Sykli is a distributed system that happens to do CI.
>
> That's not a subtle difference. It's the whole point.
