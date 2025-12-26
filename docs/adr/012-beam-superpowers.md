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

## Implementation Phases

### Phase 1: Local Mesh

- mDNS discovery on local network
- Shared cache between laptop and teammates
- Basic remote observation

### Phase 2: Cloud Mesh

- Explicit node discovery for CI runners
- Secure cookie + TLS
- Full distributed cache

### Phase 3: Hot Updates

- Config push across mesh
- Target registration without restart
- Worker scaling

### Phase 4: Advanced Observability

- Full TUI for process inspection
- Distributed tracing (no OpenTelemetry needed)
- Memory profiling

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

## The Philosophy

> **The runtime is the platform.**
>
> Other CI tools are applications that happen to be distributed.
> Sykli is a distributed system that happens to do CI.
>
> That's not a subtle difference. It's the whole point.
