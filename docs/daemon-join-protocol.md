# Sykli Daemon Join Protocol

## Status

Implemented. PR #192 added the join/heartbeat slice (coordinator
daemon-session endpoints, `sykli daemon join`, local session persistence,
`sykli daemon status --json`); later phases added work sync, run summary
sync, and gate decision sync. The production heartbeat **loop**
(`Sykli.Daemon.Heartbeat`) ships in the Monster Phase D series: hosted by
`sykli daemon join --stay` (foreground, no BEAM distribution) and by the
mesh daemon supervisor, it implements the cadence, backoff, revocation
stop, decision application + acknowledgement, outbox drain on reconnect,
automatic rejoin on session death, and the final offline heartbeat on
graceful shutdown described below. The black-box case `COORD-006` proves
the gate-decision round-trip end to end.

Event-stream delivery (SSE) remains future work.

## Architecture sentence

> The daemon executes and records; the mesh dispatches inside trusted
> networks; the coordinator synchronizes team state across locations;
> `.sykli/` remains the local source of detailed evidence.

The join protocol is the door through which a daemon enters the
coordinator's view. Nothing else in Team Mode works without it.

## Outbound connection model

The protocol is **always daemon-to-coordinator over HTTPS**.

- The daemon initiates the TCP and TLS handshake.
- The coordinator never opens a connection back to the daemon.
- The coordinator does not know the daemon's IP address beyond what
  the request presented; it never tries to reach it.
- The protocol traverses NAT, residential ISPs, corporate proxies, and
  outbound-only firewalls without changes.
- HTTP/1.1 is required. HTTP/2 is allowed if both sides support it.
- WebSockets are **not** required in v0. SSE on a future endpoint is
  acceptable for streaming. See `docs/self-hosted-coordinator.md`.

The daemon must:

- Verify the coordinator's TLS certificate against the system trust
  store, with the same hostname-checking rules as the rest of Sykli's
  HTTP layer (see `Sykli.HTTP.ssl_opts/1`).
- Prefer HTTPS for non-local coordinator URLs. The current implementation
  also supports plain HTTP for the local coordinator skeleton and tests;
  production deployments should terminate TLS at an ingress or proxy.
- Carry an `Authorization: Bearer <token>` header on every request that
  needs authentication.

The coordinator must:

- Reject any request whose token is missing, malformed, expired, revoked,
  or scoped to a different org/team.
- Rate-limit join attempts per source IP and per token in the durable
  production coordinator. The current in-memory skeleton does not include
  rate limiting yet.

## Daemon identity

Two ids matter:

- `daemon_id` — stable, operator-chosen, unique within a team. Survives
  reboots, reinstalls, and reconnections. Default: machine hostname,
  overridable with `--name`.
- `session_id` — issued by the coordinator on join. Lives only as long
  as the daemon is connected. A new join produces a new `session_id`
  even for the same `daemon_id`.

Both are required. `daemon_id` lets the team reason about a stable agent
("Yair's MacBook"), and `session_id` lets the coordinator reason about
liveness without trusting the daemon's clock.

## Example invocation

```bash
sykli daemon join \
  --coordinator https://sykli.internal \
  --org false-systems \
  --team platform \
  --token $SYKLI_TEAM_TOKEN \
  --labels macos,docker,typescript \
  --name yair-mbp
```

The token is read from the environment, not the command line, in
production. `--token` accepts a value for one-shot use; the canonical
form is `SYKLI_TEAM_TOKEN`.

## Join request

```http
POST /v1/daemon-sessions HTTP/1.1
Host: sykli.internal
Authorization: Bearer <SYKLI_TEAM_TOKEN>
Content-Type: application/json
```

```json
{
  "daemon_id": "yair-mbp",
  "org": "false-systems",
  "team": "platform",
  "labels": ["macos", "docker", "typescript"],
  "capabilities": ["local", "docker", "shell"],
  "version": "0.6.1",
  "accepts_remote_work": false
}
```

Field rules:

- `daemon_id` — required, non-empty, ≤ 128 chars, `[a-z0-9._-]+`.
- `org`, `team` — required slugs. Must match the token's scope.
- `labels` — array of strings; matches the existing mesh label vocabulary.
- `capabilities` — closed set drawn from the daemon's actual configured
  runtimes and targets (e.g. `local`, `docker`, `podman`, `shell`, `k8s`).
  The daemon must not advertise a capability it does not have.
- `version` — the daemon's `sykli` version string.
- `accepts_remote_work` — explicit. Defaults to `false` if omitted. The
  coordinator must treat omission as `false`. The daemon must require an
  explicit `--accept-remote-work` (or config equivalent) to send `true`.

## Coordinator response

```json
{
  "ok": true,
  "version": "1",
  "data": {
    "session_id": "sess_123",
    "heartbeat_interval_seconds": 15,
    "team_id": "team_123",
    "policy": {
      "sync_run_summaries": true,
      "sync_evidence_refs": true,
      "upload_raw_logs_by_default": false
    }
  },
  "error": null
}
```

Field rules:

- `session_id` — opaque, ≤ 128 chars, scoped to this session only.
- `heartbeat_interval_seconds` — the daemon must send the next heartbeat
  within this many seconds of the previous successful heartbeat. The
  coordinator picks the value; the daemon does not negotiate it.
- `team_id` — the resolved team's id. The daemon stores it for later
  requests but does not need to display it.
- `policy` — coordinator-side configuration the daemon must obey when
  deciding what to sync. Initial keys:
  - `sync_run_summaries` — daemon must POST run summaries when true.
  - `sync_evidence_refs` — daemon must register evidence refs when true.
  - `upload_raw_logs_by_default` — see `docs/team-mode-security.md`. The
    default and only secure value for v0 is `false`.

If the coordinator rejects the join, the response uses the standard error
envelope with a code from `docs/error-codes.md`. Implemented examples
include:

- `coordinator.unauthorized`
- `coordinator.org_not_found`
- `coordinator.team_not_found`
- `coordinator.invalid_daemon_id`
- `coordinator.invalid_daemon_payload`

## Heartbeat

Every `heartbeat_interval_seconds`, the daemon POSTs:

```http
POST /v1/daemon-sessions/sess_123/heartbeat HTTP/1.1
Authorization: Bearer <SYKLI_TEAM_TOKEN>
Content-Type: application/json
```

```json
{
  "session_id": "sess_123",
  "status": "available",
  "current_work_item_id": null,
  "labels": ["macos", "docker", "typescript"],
  "capabilities": ["local", "docker", "shell"],
  "last_run_id": "run_456"
}
```

Field rules:

- `status` — one of `available`, `busy`, `offline`, `degraded`, or
  `draining`. `draining` means the daemon is finishing in-flight work but
  will not accept new work; it is the equivalent of the SIGTERM drain
  behavior in `Sykli.Application`.
- `current_work_item_id` — if the daemon is currently running a work item.
- `labels` and `capabilities` — re-sent on every heartbeat. The
  coordinator treats the latest heartbeat as authoritative. A daemon may
  reduce its labels (Docker died, GPU disconnected) without rejoining.
- `last_run_id` — the most recent run the daemon has reported. The
  coordinator uses this to detect dropped run summaries.

The heartbeat response is the daemon's future pickup channel for shared
decisions:

```json
{
  "ok": true,
  "version": "1",
  "data": {
    "next_heartbeat_seconds": 15,
    "decisions": [
      {
        "type": "gate.approved",
        "gate_id": "gate_789",
        "decided_by": "yair",
        "reason": "Evidence reviewed",
        "decided_at": "2026-05-08T12:34:56Z"
      }
    ],
    "assignments": [
      {
        "work_item_id": "work_42",
        "assigned_at": "2026-05-08T12:34:50Z"
      }
    ]
  },
  "error": null
}
```

The current implementation returns empty `decisions` and `assignments`
arrays because work sync and gate sync are later phases. Once those
phases land, the daemon must process every entry it receives
idempotently; the coordinator may re-send a decision if the previous
heartbeat's response was dropped.

If the coordinator returns 401/403, the daemon must stop sending and
surface the failure to the operator. It must not retry blindly with
the same token.

## Heartbeat liveness

- Coordinator marks `daemon_sessions.status = offline` if no heartbeat
  arrives within `heartbeat_interval_seconds * 3`.
- An offline session may still be resumed by the same `session_id` if
  the gap is short. The exact cutoff is implementation-defined; a
  reasonable default is 5 minutes.
- After the cutoff, the `session_id` is dead. A new join is required.

## Capability and label announcement

A daemon advertises both **labels** (operator intent: `gpu`, `macos`,
`docker`) and **capabilities** (engine reality: `local`, `docker`,
`shell`, `k8s`). The two have different uses:

- Labels are operator-defined strings. The coordinator may match them
  against work item requirements but does not interpret their meaning.
- Capabilities are drawn from a closed engine vocabulary. The
  coordinator (and future placement logic) interprets them strictly.

A daemon must not advertise a capability it cannot serve. The engine's
`Sykli.Runtime.Resolver` is authoritative for what is available locally.

## `accepts_remote_work` flag

A daemon that holds `accepts_remote_work: false` may:

- Create work items on behalf of its operator.
- Claim work items its operator manually selected.
- Run pipelines its operator started locally.
- Report run summaries, gate states, and evidence refs.

A daemon that holds `accepts_remote_work: false` may **not**:

- Be assigned a work item by another operator's CLI.
- Be assigned a work item by a coordinator scheduling decision.
- Receive any "go run this" instruction from the coordinator.

Default is `false`. The CLI must require an explicit
`--accept-remote-work` flag (or equivalent config) to set it true. The
daemon must log loudly when this flag is enabled.

This is the seam that prevents the coordinator from becoming a remote
shell. Without explicit consent, the coordinator can only observe.

## Sync events (daemon → coordinator)

The daemon emits the following events as POSTs to the relevant API:

- `work.created` — `POST /v1/work-items`
- `work.claimed` — `POST /v1/work-items/:id/claim`
- `run.started` — `POST /v1/runs`
- `run.node.updated` — `POST /v1/runs/:id/nodes`
- `success_criteria.failed` — recorded under `POST /v1/runs/:id/nodes`
  with the criterion result body
- `review.completed` — recorded under `POST /v1/runs/:id/nodes` with
  the review result body
- `gate.requested` — `POST /v1/gates`
- `gate.decided` — `POST /v1/gates/:id/decisions` (approve or reject;
  originates from a CLI/MCP call against the coordinator, not the daemon)
- `run.completed` — `PATCH /v1/runs/:id`
- `evidence.ref.created` — `POST /v1/evidence-refs`

Every event must carry the originating `daemon_id`, `run_id` (when
applicable), and `contract_hash` (for runs). Each event must be
idempotent on retry: the coordinator de-duplicates by
`(daemon_id, run_id, node_id, kind)` for run-level events and by
explicit ids for work and gates.

## Sync events (coordinator → daemon)

Delivered as the `decisions` and `assignments` arrays in the heartbeat
response (see above). Future expansions may add an SSE stream
(`GET /v1/events/stream`); v0 correctness does not require it.

## Disconnect and reconnect

Disconnect (graceful):

- The daemon receives SIGTERM or `sykli daemon stop`.
- It transitions to `status: draining` on the next heartbeat.
- It finishes in-flight work and records run summaries.
- It POSTs a final heartbeat with `status: offline` if reachable, then
  closes.

Disconnect (network failure):

- The daemon's heartbeat fails. It backs off exponentially with jitter,
  capped at `heartbeat_interval_seconds * 4`.
- Local execution continues unaffected. The daemon writes everything to
  `.sykli/` exactly as in local-only mode.
- Sync events accumulate in a per-daemon outbox (implementation detail
  of the daemon).
- On reconnect, the daemon flushes the outbox in order. Coordinator
  idempotency keys make this safe.

Reconnect:

- If the previous `session_id` is still valid (gap under the cutoff),
  the daemon may resume by sending heartbeats with that `session_id`.
- If the gap is too long, the daemon performs a fresh join and obtains
  a new `session_id`. The coordinator records the rejoin in the audit
  log.

The daemon must not invent its own retry storms. The exponential backoff
above is mandatory.

## Token revocation

The coordinator may revoke a team token at any time. On the first
heartbeat that returns 401/403:

- The daemon stops sending sync events.
- The daemon does not block local execution.
- The daemon surfaces a `team.token.revoked` error code to the operator.
- The daemon does not retry the token.

Operators rotate tokens out of band (`sykli team token create`).

## Security notes

These are summarized here and detailed in `docs/team-mode-security.md`:

- Outbound HTTPS only. No inbound to daemons.
- TLS certificate verification is mandatory.
- Tokens scoped per team. Tokens never carry execution authority for
  other daemons unless the target daemon has `accepts_remote_work: true`.
- The daemon never sends raw logs, secrets, source code, full
  stdout/stderr, or full artifacts during the join, the heartbeat, or
  any default sync event. It sends references and summaries.
- The daemon's own `.sykli/` is unaffected by any coordinator behavior.
  Secrets that masked locally remain masked. The
  `Sykli.Occurrence.SecretMasker` rules still apply.
- Audit log captures every join, rejoin, decision, and assignment.

## Failure modes and required behavior

| Situation                              | Daemon behavior                                                |
|----------------------------------------|----------------------------------------------------------------|
| Coordinator unreachable                | Continue local execution; back off heartbeats.                 |
| TLS cert invalid                       | Refuse connection. Surface error to operator. Do not retry.    |
| Token rejected                         | Stop sending events. Surface error. Do not retry until rotated.|
| Heartbeat 5xx                          | Retry with exponential backoff and jitter.                     |
| Heartbeat returns assignment but daemon has `accepts_remote_work: false` | Reject the assignment with `team.policy.refused_remote_work` and continue. |
| Daemon crashes during run              | On restart, last `.sykli/` state is the source of truth. Daemon resumes by joining and re-syncing the missing run summary. |
| Coordinator returns clock-skewed timestamp | Daemon uses its own monotonic clock for retry/backoff. Display strings honor the coordinator. |

The default rule for any unspecified failure is: **never block local
execution because of a coordination failure.**

## What this protocol is not

- It is not a remote-execution protocol.
- It is not a code-distribution mechanism.
- It is not a log shipper.
- It is not a heartbeat-based scheduler.
- It is not a federation protocol between coordinators.

Each of those, if it ever exists, gets its own design doc.

## Cross-references

- `docs/coordination-modes.md` — modes A–D.
- `docs/self-hosted-coordinator.md` — coordinator data model and API.
- `docs/team-mode-security.md` — trust model and minimization rules.
- `docs/local-state-plane.md` — what stays local versus what is synced.
