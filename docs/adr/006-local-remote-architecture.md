# ADR-006: Local/Remote Architecture — Why Elixir

**Status:** Accepted
**Date:** 2024-12-03

---

## Context

Sykli needs to run tasks both locally (developer machine) and remotely (CI workers, distributed builds). Why did we choose Elixir for this?

## Decision

**Elixir/OTP is the execution engine because local and remote are the SAME code.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    THE KEY INSIGHT                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   LOCAL execution = Single Elixir node                          │
│   REMOTE execution = Multiple Elixir nodes                      │
│                                                                 │
│   SAME code. SAME processes. SAME supervision.                  │
│   Just different topology.                                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Local Mode

```
┌─────────────────────────────────────────────────────────────────┐
│                    LOCAL EXECUTION                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Developer Machine                                             │
│   ┌───────────────────────────────────────────┐                │
│   │             Sykli Node                     │                │
│   │                                           │                │
│   │   ┌─────────────┐   ┌─────────────┐      │                │
│   │   │  Supervisor │───│  Executor   │      │                │
│   │   └─────────────┘   └─────────────┘      │                │
│   │          │                  │             │                │
│   │   ┌──────┴──────┐   ┌──────┴──────┐      │                │
│   │   │ Task: test  │   │ Task: lint  │      │                │
│   │   │ (process)   │   │ (process)   │      │                │
│   │   └─────────────┘   └─────────────┘      │                │
│   │                                           │                │
│   └───────────────────────────────────────────┘                │
│                                                                 │
│   - Single node                                                 │
│   - Tasks as Elixir processes                                   │
│   - Parallel via Task.async                                     │
│   - Fast feedback loop                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

What happens:
1. `sykli` runs on your machine
2. Parses task graph from SDK
3. Spawns Elixir processes for each task
4. Parallel execution via `Task.async_stream`
5. Results collected, build pass/fail

---

## Remote Mode

```
┌─────────────────────────────────────────────────────────────────┐
│                    REMOTE EXECUTION                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Coordinator                     Workers (dynamic)             │
│   ┌─────────────────┐            ┌─────────────────┐           │
│   │   Sykli Node    │            │  Worker Node 1  │           │
│   │   (scheduler)   │◄──────────►│                 │           │
│   │                 │            │  ┌───────────┐  │           │
│   │   - Parse graph │            │  │ Task: test│  │           │
│   │   - Distribute  │            │  └───────────┘  │           │
│   │   - Collect     │            └─────────────────┘           │
│   └─────────────────┘            ┌─────────────────┐           │
│          │                       │  Worker Node 2  │           │
│          │                       │                 │           │
│          └──────────────────────►│  ┌───────────┐  │           │
│                                  │  │ Task: lint│  │           │
│             OTP Distribution     │  └───────────┘  │           │
│                                  └─────────────────┘           │
│                                                                 │
│   - Multiple nodes                                              │
│   - Same Executor code                                          │
│   - Native Elixir clustering                                    │
│   - Workers join/leave dynamically                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

What happens:
1. Coordinator node receives task graph
2. Workers connect to coordinator (OTP clustering)
3. Coordinator distributes tasks to workers
4. **Same `Executor` code runs on workers**
5. Results flow back via message passing
6. Workers can be anywhere (same machine, VMs, containers, cloud)

---

## Why Elixir/OTP

### 1. Distribution is Built-in

```elixir
# Connect nodes (that's it)
Node.connect(:"worker@10.0.0.5")

# Spawn task on remote node
Node.spawn(:"worker@10.0.0.5", fn ->
  Sykli.Executor.run_single(task, workdir)
end)

# Or use distributed Task
Task.Supervisor.async({Sykli.TaskSupervisor, :"worker@10.0.0.5"}, fn ->
  Sykli.Executor.run_single(task, workdir)
end)
```

No HTTP APIs. No message queues. No serialization formats. Just Elixir.

### 2. Lightweight Processes

```elixir
# Spawn 10,000 concurrent tasks? No problem.
tasks
|> Enum.map(&Task.async(fn -> execute(&1) end))
|> Task.await_many()

# Each task is ~2KB of memory
# Preemptively scheduled
# Isolated failures
```

Other languages need thread pools, executors, careful resource management. Elixir just spawns.

### 3. Supervision Trees

```elixir
# If a task crashes, supervisor handles it
defmodule Sykli.TaskSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      {Task.Supervisor, name: Sykli.Tasks}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

# Tasks are supervised
Task.Supervisor.async(Sykli.Tasks, fn ->
  # If this crashes, supervisor knows
  execute_task(task)
end)
```

### 4. Same Code, Different Topology

This is the killer feature:

```elixir
defmodule Sykli.Executor do
  # This SAME function runs locally OR on a remote worker
  def run_single(task, workdir, opts \\ []) do
    # ... execute the task ...
  end
end

# Local: called directly
Executor.run_single(task, workdir)

# Remote: called on another node
Task.Supervisor.async({Sykli.Tasks, remote_node}, fn ->
  Executor.run_single(task, workdir)  # Same function!
end)
```

No separate "worker" codebase. No gRPC definitions. No protocol buffers.

### 5. Hot Code Reloading

```elixir
# Update worker code without stopping
# Workers can receive new versions while running builds
# Zero downtime deployments of the CI itself
```

---

## Comparison: Why Not Other Languages?

| Feature | Elixir/OTP | Go | Rust | Node.js |
|---------|-----------|-----|------|---------|
| Native distribution | Yes (built-in) | No (need gRPC/HTTP) | No (need gRPC/HTTP) | No |
| Lightweight processes | Yes (millions) | Goroutines (good) | Threads (heavy) | Single-threaded |
| Supervision | Yes (built-in) | Manual | Manual | Manual |
| Same code local/remote | Yes | No | No | No |
| Message passing | Native | Channels (local only) | Channels (local only) | Events |
| Fault tolerance | Excellent | Manual | Manual | Poor |

### Go Alternative

Would need:
- gRPC for communication
- Protocol buffers for serialization
- Worker binary that's different from coordinator
- Manual connection management
- Manual failure handling

### The Elixir Advantage

```
Other languages: Build two systems (coordinator + worker)
Elixir: Build one system that scales from 1 to N nodes
```

---

## Architecture Vision

```
┌─────────────────────────────────────────────────────────────────┐
│                    SYKLI ARCHITECTURE                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   SDK (Go/Rust/TS)                                              │
│   └── Emits JSON task graph                                     │
│                                                                 │
│   Core (Elixir)                                                 │
│   ├── Detector: Find & run SDK                                  │
│   ├── Graph: Parse JSON, topo sort                              │
│   ├── Scheduler: Decide where to run                            │
│   │   ├── Local: run here                                       │
│   │   └── Remote: distribute to workers                         │
│   ├── Executor: Run single task                                 │
│   │   └── Same code everywhere                                  │
│   └── Reporter: GitHub status, logs, artifacts                  │
│                                                                 │
│   Workers (Same Elixir release)                                 │
│   ├── Connect to coordinator                                    │
│   ├── Receive tasks via OTP                                     │
│   ├── Run Executor (same code)                                  │
│   └── Report results back                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Mode Selection

```go
// In SDK: hint about where to run
s := sykli.New()

// Local (default)
s.Task("test").Run("go test ./...")

// Request remote for heavy tasks
s.Task("build").Run("go build").Remote()

// Or let Sykli decide based on resources
s.Task("heavy").Run("...").Prefer(sykli.Remote)
```

```elixir
# In Core: Scheduler decides
defmodule Sykli.Scheduler do
  def schedule(task, graph, opts) do
    cond do
      task.remote == true -> schedule_remote(task)
      opts[:force_remote] -> schedule_remote(task)
      has_available_workers?() -> schedule_remote(task)
      true -> schedule_local(task)
    end
  end
end
```

---

## Worker Discovery

### Option A: Static Configuration
```elixir
# config/runtime.exs
config :sykli, :workers, [
  :"worker1@10.0.0.5",
  :"worker2@10.0.0.6"
]
```

### Option B: Dynamic Discovery (libcluster)
```elixir
# Workers auto-discover via DNS, Kubernetes, etc.
config :libcluster,
  topologies: [
    sykli: [
      strategy: Cluster.Strategy.Kubernetes.DNS,
      config: [
        service: "sykli-workers",
        application_name: "sykli"
      ]
    ]
  ]
```

### Option C: Fly.io Style
```elixir
# Workers on Fly.io auto-cluster
config :libcluster,
  topologies: [
    fly6pn: [
      strategy: Cluster.Strategy.DNSPoll,
      config: [
        polling_interval: 5_000,
        query: "sykli.internal",
        node_basename: "sykli"
      ]
    ]
  ]
```

---

## The Scaling Story

```
DAY 1: Local only
└── Single developer, single machine
└── sykli runs, tasks execute locally

DAY 30: Team grows
└── Still local on dev machines
└── CI runs sykli with remote workers (same binary!)
└── Workers are just more instances

DAY 100: Scale up
└── Add more workers (just deploy more instances)
└── Coordinator handles distribution
└── Zero code changes

DAY 365: Enterprise
└── Multi-region workers
└── Cache layer (still same Executor)
└── Just topology changes
```

---

## Summary

| Aspect | Why Elixir |
|--------|-----------|
| **Distribution** | Built into the language (OTP) |
| **Parallelism** | Millions of lightweight processes |
| **Fault tolerance** | Supervision trees, let it crash |
| **Same code** | Executor runs locally AND remotely |
| **Scaling** | Add nodes, not complexity |
| **Message passing** | Native, efficient, no serialization |

---

**Local and remote aren't different modes. They're the same system at different scales.**

