# ADR 013: Mesh Swarm Design

## Status
Proposed

## Context

Sykli's mesh feature (`--mesh`) enables distributed task execution across BEAM nodes. However, the current implementation is "all or nothing" - either you're local or you're in the mesh. Senior developers need **configurable magic** - knobs to control how much distribution happens.

Real-world teams have heterogeneous network conditions:
- **Office LAN**: Fast, reliable, low latency (Jimbo, Clark, Jamil)
- **Cross-subnet**: Same building, different network class (Gorgo on Class B)
- **Home/VPN**: Stable WAN behind NAT (Johannes)
- **Mobile**: High jitter, intermittent (Zeko on 5G train)
- **Hostile**: Extreme latency, packet loss, tormented (Manfred)

The BEAM was designed for exactly this - Ericsson phone switches on noisy 1980s copper.

## Decision

### 1. Three Operational Modes

| Mode | Command | Behavior |
|------|---------|----------|
| **Solo** | `sykli run` | Local only. No mesh, no stealing. |
| **Mesh** | `sykli run --mesh` | Join mesh. Dispatch to idle nodes. No stealing. |
| **Swarm** | `sykli run --mesh --steal` | Full magic. Idle nodes proactively pull work. |

### 2. Connection-Aware Stealing Policy

```elixir
# .sykli/config.exs
config :sykli, :mesh,
  stealing: true,
  steal_policy: %{
    max_concurrent: 2,           # Don't hoard tasks
    require_labels: [:gpu],      # Affinity requirements
    min_memory_gb: 4,            # Resource floor
    max_artifact_mb: 500,        # Don't steal huge builds over WAN
    consent_timeout_ms: 1000     # How long to wait for approval
  }
```

### 3. Node Profiles

Nodes advertise their connection quality and capabilities:

```elixir
config :sykli, :node_profile,
  labels: [:gpu, :docker, :linux],
  connection: :lan,           # :lan | :wan | :mobile | :hostile
  stealing: :full,            # :full | :receive_only | :disabled
  tick_time: 60_000           # ms between heartbeats
```

**Connection presets:**

| Profile | Tick Time | Stealing | Artifacts | Use Case |
|---------|-----------|----------|-----------|----------|
| `:lan` | 60s | Full | Unlimited | Office |
| `:wan` | 120s | Full | 500MB max | Home/VPN |
| `:mobile` | 300s | Disabled | Status only | 5G train |
| `:hostile` | 600s | Receive only | None | Hell |

### 4. Hybrid Discovery Strategy

Different topologies for different network conditions:

```elixir
topologies = [
  # Office core - fast multicast discovery
  office_lan: [
    strategy: Cluster.Strategy.Gossip,
    config: [port: 45892]
  ],

  # Remote workers - VPN/Tailscale mesh
  remote_mesh: [
    strategy: Cluster.Strategy.Epmd,
    config: [hosts: [:"server@sykli.internal"]]
  ],

  # Mobile/hostile - hidden nodes, pull-only
  hidden_mesh: [
    strategy: Cluster.Strategy.Epmd,
    config: [hosts: [:"server@sykli.internal"]],
    hidden: true
  ]
]
```

### 5. Consent Protocol for Work Stealing

No silent magic. Explicit handshake:

```
┌─────────────┐                    ┌─────────────┐
│   Sarah     │                    │    Dave     │
│  (busy)     │                    │  (idle)     │
└──────┬──────┘                    └──────┬──────┘
       │                                  │
       │◀── {:idle, capabilities} ────────│
       │                                  │
       │── {:offer, task_id, size} ──────▶│
       │                                  │
       │◀── {:accept, task_id} ───────────│
       │                                  │
       │── {:task_bundle, ...} ──────────▶│
       │                                  │
       │◀── {:started, task_id} ──────────│
       │                                  │
       │◀── {:completed, result} ─────────│
```

### 6. Visibility in Status Graph

Remote execution must be obvious in the UI:

```
lint ✓ → test ✓ → build ⚡dave-macbook → deploy ⏳

Legend:
  ✓  = passed (local)
  ⚡ = running remotely
  ⏳ = pending
  ✗  = failed
```

Task detail view:
```
[Task: build] Status: Running
  Executor: dave-macbook (192.168.1.42)
  Stolen: yes (from sarah-laptop)
  Progress: 45%
```

### 7. The Hidden Node Pattern

For mobile/hostile connections (Zeko, Manfred):

```elixir
# Node connects but doesn't accept incoming connections
# Prevents office nodes from wasting bandwidth on flaky heartbeats
Node.start(:"zeko@mobile", :shortnames, hidden: true)
```

Hidden nodes:
- Can see the full mesh status
- Can receive tasks (if stealing enabled)
- Don't trigger `:nodedown` storms when connection drops
- Reconnect gracefully without disrupting the swarm

## Consequences

### Positive

- **Predictability**: Default is local. Magic is opt-in.
- **Trust**: Developers control exactly how much distribution happens.
- **Resilience**: Connection-aware policies prevent bad experiences.
- **Visibility**: No silent task migrations. UI always shows where work runs.
- **Heterogeneous teams**: Same codebase works for LAN, WAN, mobile, and hostile networks.

### Negative

- **Configuration complexity**: More knobs to understand.
- **Discovery overhead**: Multiple topology strategies add complexity.
- **Testing**: Need to test all connection profiles.

### Neutral

- The BEAM handles the hard parts (distribution, failover, message passing).
- Tailscale/VPN recommended for cross-NAT teams.

## Implementation Notes

### Phase 1: Foundation (v0.2.x)
- [x] Basic mesh (`--mesh` flag)
- [x] Dispatch to idle nodes
- [ ] Node profiles and labels

### Phase 2: Stealing (v0.3.0)
- [ ] `--steal` flag
- [ ] Consent protocol
- [ ] Connection-aware policies
- [ ] Status graph indicators

### Phase 3: Resilience (v0.3.x)
- [ ] Hidden node support
- [ ] Adaptive tick times
- [ ] Graceful reconnection
- [ ] The Manfred Protocol (hostile network handling)

## References

- [Erlang Distribution Protocol](https://www.erlang.org/doc/apps/erts/erl_dist_protocol.html)
- [libcluster - Automatic BEAM clustering](https://github.com/bitwalker/libcluster)
- [Tailscale - Zero-config mesh VPN](https://tailscale.com/)
- [Build distributed systems on an untrusted substrate with Erlang](https://www.youtube.com/watch?v=example) - Code BEAM talk

---

*"Works on my machine, works in CI, works in literal eternal damnation"*
*— Manfred, Senior Developer (Damned)*
