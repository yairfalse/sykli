# Sykli Self-Hosted Coordinator

## Status

Design and implementation reference for the Sykli Coordinator service.
The initial skeleton is implemented with an in-memory store,
admin bootstrap token auth, signed team tokens, org/team/work item
endpoints, run sync, gate sync, and daemon join/heartbeat endpoints.
Durable Postgres storage and deployment manifests remain future
implementation slices.

## Product sentence

Sykli is local-first execution with self-hosted team coordination.

Long form:

> Sykli lets teams run agentic work where they trust it — locally, in
> Kubernetes, or on trusted workers — while coordinating work items,
> assignments, runs, gates, approvals, and evidence through a self-hosted
> coordinator.

## Architecture sentence

> The daemon executes and records; the mesh dispatches inside trusted
> networks; the coordinator synchronizes team state across locations;
> `.sykli/` remains the local source of detailed evidence.

## Purpose

The coordinator gives a team one shared, self-hosted source of truth for:

- which work items exist
- who claimed them
- which runs were executed
- which gates are waiting
- which approvals were granted
- where the detailed evidence lives

It does **not** become the runtime. It does not own logs, artifacts,
secrets, or source code. Execution authority remains with each daemon and
its configured target (Local, Docker/Podman/Shell, or Kubernetes).

## Non-goals

The coordinator does **not** do any of the following in v0:

- Remote shell or RPC into developer laptops.
- Full log storage or hosted log search.
- Artifact storage.
- Source-code storage.
- Secret storage or distribution.
- Billing.
- Complex RBAC. Roles are limited to `owner`, `member`, `approver`.
- Global scheduling. The coordinator does not pre-empt local execution.
- LLM provider integration (OpenAI, Anthropic, etc.).
- Hosted SaaS behavior. The coordinator runs only in infrastructure the
  user controls.
- Web UI. The CLI and `--json` output are the surfaces.
- Refactor of the existing BEAM mesh. The coordinator is additive.

These restrictions are not aspirational. They define what the coordinator
must keep out to remain local-first and self-hosted.

## High-level architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                Sykli Coordinator (self-hosted)              │
│                                                             │
│  HTTP/JSON API (v1)        ──┐                              │
│  Postgres (state)            │                              │
│  Audit log                   │   inbound HTTPS only         │
│  Token issuer                │                              │
│  (optional) SSE event stream │                              │
└──────────────────────────────┴──────────────────────────────┘
                ▲                              ▲
                │ outbound HTTPS only          │ outbound HTTPS only
                │                              │
        ┌───────┴────────┐             ┌──────┴────────┐
        │ Sykli daemon A │             │ Sykli daemon B│
        │ (laptop)       │             │ (K8s gateway) │
        │ executes locally             │ dispatches to │
        │ writes .sykli/ │             │ trusted mesh  │
        └────────────────┘             └───────────────┘
```

Properties:

- **No inbound network to daemons.** Daemons always initiate the
  connection. The coordinator never opens a socket to a laptop.
- **No Erlang distribution between coordinator and daemons.** The
  coordinator does not hold a BEAM cookie shared with daemons. The
  protocol is HTTP/JSON.
- **No execution on the coordinator.** It does not run user pipelines.
- **One process surface.** All state is in one Postgres database. No
  Kafka, Redis, or external broker is required to start.

## Authorization model

`SYKLI_COORDINATOR_TOKEN` is the admin bootstrap token. It has owner
access to all coordinator endpoints and is the signing secret used by
`sykli coordinator mint-token`.

Team tokens are stateless signed bearer tokens carrying `{org, team,
role}` claims. The current token format has no expiry claim; rotation is
done by rotating the coordinator token/signing secret. Roles are:

- `owner` — team-scoped read/write access, including gate decisions.
- `approver` — team-scoped access and gate decisions.
- `member` — team-scoped work/run/session/gate access, but not gate
  decisions.

List endpoints are scoped to the token's team. If a team token supplies
a conflicting `org_id`, `team_id`, `org_slug`, or `team_slug`, the API
returns `403 coordinator.forbidden` instead of widening the query.
Single-resource endpoints also enforce the stored resource's team.

## Coordinator responsibilities (v0)

The v0 coordinator does only this:

- Org and team registry.
- Daemon join, heartbeat, and session tracking.
- Work item creation, listing, claiming, assignment, notes.
- Run summary recording (status, target, started/finished, error code).
- Per-node run status (kind, status, error code, evidence ref).
- Gate request, approval, rejection.
- Evidence reference sync (URI + hash + visibility, never the artifact).
- Mandatory append-only audit log.

That is the entire feature surface for v0. Anything else waits for a
later design doc.

## Sync model

The coordinator is the **shared projection**. The local `.sykli/` directory
is the **detailed local truth**. The relationship is documented in
`docs/local-state-plane.md`.

The default sync direction is **daemon → coordinator** for state changes
(run started, run completed, gate requested) and **coordinator → daemon**
for shared decisions (gate approved, work claimed by someone else).

Initial transport choices:

- Daemons POST events to the coordinator over HTTPS.
- Daemons poll for new shared decisions on each heartbeat.
- A future `GET /v1/events/stream` endpoint may stream events via
  Server-Sent Events. **WebSockets are not required in v0.** SSE is
  preferred because it is one-way, HTTP-shaped, and crosses proxies
  cleanly.

The coordinator does not push to daemons. Daemons reach the coordinator;
the coordinator does not reach daemons.

## Storage recommendation

- **Postgres** for v0. Boring, durable, well-understood, available in
  every operator's cluster.
- One database, one schema, one migration tool (Ecto or equivalent in the
  implementation language; this is a coordinator-internal decision).
- Audit log is append-only. The coordinator never deletes audit log rows.
- No Kafka, no Redis, no external broker in v0.

Future versions may add object storage for opt-in evidence uploads, but
that is out of scope here.

### Current skeleton storage

The first implementation slice uses an in-memory coordinator store. This
is deliberately not production persistence. It stabilizes the HTTP API,
auth boundary, JSON envelopes, and tests before the Postgres-backed store
and migrations land.

Current behavior:

- `sykli coordinator start --token <token>` starts the coordinator
  skeleton on `127.0.0.1` by default.
- `--bind <address>` may expose it on another interface, for example
  `--bind 0.0.0.0` behind a TLS-terminating ingress or proxy.
- The skeleton speaks plain HTTP; production deployments must terminate
  TLS at the ingress or proxy until in-process TLS is explicitly added.
- State is lost when the coordinator process exits.
- State-changing calls append in-memory audit events.
- Daemon join and heartbeat sessions are stored in memory and are lost
  when the coordinator exits.
- `sykli work create/list/show/claim/note --team <team>` can operate
  against the coordinator after `sykli daemon join` writes a local
  session file.
- Team work commands require `SYKLI_TEAM_TOKEN`; the daemon session file
  stores coordinator metadata but not the bearer token.
- Team work commands fail rather than falling back to local `.sykli/`
  state when the coordinator is unavailable or authorization fails.
- Durable Postgres storage, migrations, and deployment assets remain
  follow-up work.

## Security defaults

Documented in detail in `docs/team-mode-security.md`. The short version:

- Daemons connect outbound only.
- TLS is required.
- Authentication starts as **org/team join tokens**. OIDC and GitHub org
  mapping are deferred.
- Raw logs, artifacts, secrets, source code, and full stdout/stderr are
  **never** synced by default.
- A daemon must declare `accepts_remote_work: true` to receive work
  originated by another daemon. Default is `false`.
- Audit log is mandatory.
- The LAN mesh trust model and the coordinator trust model are different.
  See `docs/team-mode-security.md` for the explicit distinction.

## Deployment shape

The coordinator is intended to be deployed as a single Kubernetes
workload in a cluster the operator already runs. Components:

- `Deployment: sykli-coordinator` — the API process.
- `Service: sykli-coordinator` — ClusterIP.
- Optional `Ingress` — for HTTPS access from daemons outside the cluster.
- Postgres — operator-managed, in-cluster or external.
- `Secret: sykli-coordinator-token` — coordinator signing/authentication
  secret used to mint and verify team tokens.
- `Secret: sykli-db-url` — Postgres URL.
- `ConfigMap: sykli-coordinator-config` — non-secret configuration.
- `ServiceAccount` with minimal RBAC. The coordinator does not need
  cluster-admin; it does not run user workloads.

Example Helm-style values (illustrative, not normative for v0):

```yaml
coordinator:
  image: false-systems/sykli-coordinator
  replicas: 1

database:
  urlFromSecret: sykli-db-url

auth:
  tokenSecret: sykli-coordinator-token

ingress:
  enabled: true
  host: sykli.internal.false.systems

sync:
  uploadRawLogsByDefault: false
  allowRemoteExecutionByDefault: false
```

The actual chart or kustomization lands in Phase 9
(`docs/team-mode-roadmap.md`). It is not part of this PR.

## Data model v0

The schema below is the conceptual shape. Column types, indexes, and
exact constraints will be specified by the migration in Phase 4. Names
are normative; types are illustrative.

### `orgs`

| column      | type        | notes                              |
|-------------|-------------|------------------------------------|
| `id`        | ulid/uuid   | primary key                        |
| `slug`      | text unique | url-safe identifier (e.g. `false-systems`) |
| `name`     | text        | display name                       |
| `created_at`| timestamptz | UTC                                |

### `teams`

| column      | type      | notes                                    |
|-------------|-----------|------------------------------------------|
| `id`        | ulid/uuid | primary key                              |
| `org_id`    | fk orgs   | required                                 |
| `slug`      | text      | unique within org                        |
| `name`      | text      | display name                             |
| `created_at`| timestamptz | UTC                                    |

### `members`

| column        | type      | notes                                  |
|---------------|-----------|----------------------------------------|
| `id`          | ulid/uuid | primary key                            |
| `org_id`      | fk orgs   | required                               |
| `display_name`| text      | shown in CLI                           |
| `email`       | text      | identity hint, not authentication      |
| `role`        | enum      | `owner` \| `member` \| `approver`     |
| `created_at`  | timestamptz | UTC                                  |

Roles in v0:

- `owner` — manage org, teams, tokens, members.
- `member` — create/claim/run work.
- `approver` — approve or reject gates.

That is the entire RBAC. Per-resource ACLs are deferred.

### `daemon_sessions`

| column             | type      | notes                                   |
|--------------------|-----------|-----------------------------------------|
| `id`               | ulid/uuid | primary key (the `session_id`)          |
| `org_id`           | fk orgs   | required                                |
| `team_id`          | fk teams  | required                                |
| `daemon_id`        | text      | stable per-daemon identifier            |
| `display_name`     | text      | e.g. `yair-mbp`                         |
| `status`           | enum      | `online` \| `offline` \| `busy`         |
| `labels_json`      | jsonb     | array of strings                        |
| `capabilities_json`| jsonb     | array of strings                        |
| `accepts_remote_work` | bool   | default `false`                         |
| `last_seen_at`     | timestamptz | updated on every heartbeat            |
| `created_at`       | timestamptz | UTC                                   |

### `work_items`

| column              | type       | notes                                      |
|---------------------|------------|--------------------------------------------|
| `id`                | ulid/uuid  | primary key                                |
| `org_id`            | fk orgs    | required                                   |
| `team_id`           | fk teams   | required                                   |
| `title`             | text       | one-line description                       |
| `intent`            | text       | longer prose; agent-readable               |
| `status`            | enum       | see below                                  |
| `created_by`        | actor ref  | `(type, id)` pair                          |
| `assigned_to_type`  | enum       | `member` \| `agent` \| `daemon` \| null   |
| `assigned_to_id`    | text       | actor identifier                           |
| `created_at`        | timestamptz| UTC                                        |
| `updated_at`        | timestamptz| UTC                                        |

`status` values: `open`, `claimed`, `running`, `blocked`, `done`,
`failed`, `cancelled`.

### `work_notes`

| column         | type       | notes                          |
|----------------|------------|--------------------------------|
| `id`           | ulid/uuid  | primary key                    |
| `work_item_id` | fk         | required                       |
| `author_type`  | enum       | `member` \| `agent` \| `daemon`|
| `author_id`    | text       | actor identifier               |
| `body`         | text       | markdown allowed               |
| `created_at`   | timestamptz| UTC                            |

### `contracts`

| column            | type       | notes                                       |
|-------------------|------------|---------------------------------------------|
| `id`              | ulid/uuid  | primary key                                 |
| `work_item_id`    | fk         | nullable; contracts may exist before claim  |
| `schema_version`  | text       | `"1"` \| `"2"` \| `"3"`                     |
| `contract_hash`   | text       | sha256 of canonical JSON                    |
| `summary`         | text       | short human-readable digest                 |
| `raw_contract_json` | jsonb    | **opt-in upload only**                      |
| `created_by`      | actor ref  | `(type, id)`                                |
| `created_at`      | timestamptz| UTC                                         |

Default behavior is to store `contract_hash` and `summary`. Uploading
`raw_contract_json` is explicit per-team policy and per-call.

### `runs`

| column         | type        | notes                                 |
|----------------|-------------|---------------------------------------|
| `id`           | ulid/uuid   | primary key                           |
| `work_item_id` | fk          | nullable                              |
| `contract_id`  | fk          | required                              |
| `daemon_id`    | text        | the executing daemon                  |
| `status`       | enum        | see below                             |
| `target`       | text        | `local` \| `k8s` \| etc.              |
| `started_at`   | timestamptz | nullable until the run starts         |
| `finished_at`  | timestamptz | nullable until the run terminates     |
| `summary`      | text        | one-line digest                       |
| `error_code`   | text        | from `docs/error-codes.md` if any     |
| `created_at`   | timestamptz | UTC                                   |
| `updated_at`   | timestamptz | UTC                                   |

`status` values: `pending`, `running`, `passed`, `failed`, `blocked`,
`cancelled`, `errored`. The `failed` vs `errored` distinction matches the
engine's `TaskResult` semantics: content failure vs infrastructure failure.

### `run_nodes`

| column         | type        | notes                                  |
|----------------|-------------|----------------------------------------|
| `id`           | ulid/uuid   | primary key                            |
| `run_id`       | fk          | required                               |
| `node_id`      | text        | the contract's task id                 |
| `kind`         | enum        | `task` \| `review` \| `gate` \| `verify` |
| `status`       | enum        | matches engine `TaskResult` statuses   |
| `started_at`   | timestamptz | nullable                               |
| `finished_at`  | timestamptz | nullable                               |
| `summary`      | text        | one-line digest                        |
| `error_code`   | text        | nullable                               |

### `success_criteria_results`

| column          | type       | notes                                   |
|-----------------|------------|-----------------------------------------|
| `id`            | ulid/uuid  | primary key                             |
| `run_id`        | fk         | required                                |
| `node_id`       | text       | the executing task                      |
| `criterion_id`  | text       | stable id of the criterion              |
| `kind`          | enum       | `exit_code` \| `file_exists` \| `file_non_empty` |
| `status`        | enum       | `passed` \| `failed` \| `unsupported`   |
| `message`       | text       | human-readable explanation              |
| `evidence_ref_id`| fk        | optional pointer to `evidence_refs`     |
| `created_at`    | timestamptz| UTC                                     |

Tracks the engine's `Sykli.SuccessCriteria` results at the team boundary.

### `review_results`

| column          | type       | notes                                          |
|-----------------|------------|------------------------------------------------|
| `id`            | ulid/uuid  | primary key                                    |
| `run_id`        | fk         | required                                       |
| `node_id`       | text       | the review node                                |
| `review_type`   | text       | e.g. `api_breakage`                            |
| `status`        | enum       | `passed` \| `failed` \| `unsupported` \| `errored` |
| `severity`      | enum       | `info` \| `warning` \| `error`                 |
| `summary`       | text       | one-line digest                                |
| `findings_json` | jsonb      | optional structured findings                   |
| `evidence_ref_id`| fk        | optional                                       |
| `created_at`    | timestamptz| UTC                                            |

### `gates`

| column            | type       | notes                                        |
|-------------------|------------|----------------------------------------------|
| `id`              | ulid/uuid  | primary key                                  |
| `work_item_id`    | fk         | nullable                                     |
| `run_id`          | fk         | required                                     |
| `node_id`         | text       | the gate node                                |
| `status`          | enum       | `waiting` \| `approved` \| `rejected` \| `blocked` \| `expired` |
| `reason`          | text       | human-supplied                               |
| `requested_by_type`| enum      | `member` \| `agent` \| `daemon`              |
| `requested_by_id` | text       |                                              |
| `decided_by`      | text       | nullable until decided                       |
| `decided_at`      | timestamptz| nullable until decided                       |
| `created_at`      | timestamptz| UTC                                          |

### `evidence_refs`

| column        | type       | notes                                            |
|---------------|------------|--------------------------------------------------|
| `id`          | ulid/uuid  | primary key                                      |
| `work_item_id`| fk         | nullable                                         |
| `run_id`      | fk         | nullable                                         |
| `node_id`     | text       | nullable                                         |
| `type`        | enum       | `occurrence` \| `attestation` \| `artifact` \| `github_check` \| `local_ref` \| `object_ref` |
| `uri`         | text       | resolvable; may be local-only                    |
| `hash`        | text       | sha256                                           |
| `summary`     | text       | optional short label                             |
| `visibility`  | enum       | `local_only` \| `team` \| `external`             |
| `created_at`  | timestamptz| UTC                                              |

`visibility = local_only` means the URI is a path on the originating
daemon's filesystem (typically inside `.sykli/`). The coordinator records
the reference; it does not fetch the object. `team` and `external`
visibility imply the referenced object is accessible at the URI from the
team or wider audience respectively.

### `audit_log`

| column         | type        | notes                                    |
|----------------|-------------|------------------------------------------|
| `id`           | ulid/uuid   | primary key                              |
| `org_id`       | fk          | required                                 |
| `team_id`      | fk          | nullable                                 |
| `actor_type`   | enum        | `member` \| `agent` \| `daemon` \| `system` |
| `actor_id`     | text        | actor identifier                         |
| `action`       | text        | e.g. `gate.approved`                     |
| `subject_type` | text        | e.g. `gate`, `work_item`, `run`          |
| `subject_id`   | text        |                                          |
| `metadata_json`| jsonb       | arbitrary structured context             |
| `created_at`   | timestamptz | UTC                                      |

The audit log is append-only. The coordinator never updates or deletes
rows. Every state-changing API call writes at least one row.

## Minimal API sketch

This is a v0 sketch, not the final contract. Endpoints are versioned
under `/v1`. All endpoints accept and return JSON. All endpoints require
TLS. All endpoints require an `Authorization: Bearer <token>` header
unless explicitly marked otherwise (e.g. `/healthz`).

Org / team:

```text
POST  /v1/orgs                       # owner only; bootstrap or invite-driven
POST  /v1/teams                      # owner only
```

Daemon session:

```text
POST  /v1/daemon-sessions            # daemon join (see daemon-join-protocol.md)
POST  /v1/daemon-sessions/:id/heartbeat
```

Work items:

```text
GET   /v1/work-items                 # list, filter by team/status/assignee
POST  /v1/work-items                 # create
GET   /v1/work-items/:id             # show
POST  /v1/work-items/:id/claim       # actor claims
POST  /v1/work-items/:id/assign      # owner/approver assigns (planned; not in current skeleton)
POST  /v1/work-items/:id/notes       # append note
```

Runs (the implemented sync posts one complete, metadata-only summary per run;
node/criteria/review/evidence refs travel inside the `POST /v1/runs` body —
there is no incremental run-node or run-patch endpoint today):

```text
POST  /v1/runs                       # daemon reports a complete run summary
GET   /v1/runs                       # list
GET   /v1/runs/:id                   # show
```

Gates:

```text
GET   /v1/gates                      # list waiting/decided
POST  /v1/gates                      # daemon registers a waiting gate
GET   /v1/gates/:id                  # show
POST  /v1/gates/:id/decisions        # approver decision (approve or reject)
```

Evidence (planned; **not in the current skeleton** — evidence refs travel
inside the `POST /v1/runs` summary body today):

```text
POST  /v1/evidence-refs              # daemon registers a reference
GET   /v1/evidence-refs/:id          # show metadata; never the object body
```

Future, not v0:

```text
GET   /v1/events/stream              # SSE; not required for v0 correctness
```

Health:

```text
GET   /health                        # unauthenticated; returns coordinator readiness
GET   /healthz                       # compatibility alias
```

Every response uses the same envelope shape Sykli already uses for `--json`
output (`Sykli.CLI.JsonResponse`):

```jsonc
{
  "ok": true,
  "version": "1",
  "data": { /* endpoint payload */ },
  "error": null
}
```

Errors carry `{ "ok": false, "error": { "code", "message", "hints": [..] } }`
with codes from `docs/error-codes.md` extended with coordinator-specific
codes when needed.

The current skeleton implements:

```text
GET  /health
GET  /healthz
POST /v1/orgs
GET  /v1/orgs
POST /v1/teams
GET  /v1/teams
GET  /v1/work-items
POST /v1/work-items
GET  /v1/work-items/:id
POST /v1/work-items/:id/claim
POST /v1/work-items/:id/notes
POST /v1/runs
GET  /v1/runs
GET  /v1/runs/:id
POST /v1/gates
GET  /v1/gates
GET  /v1/gates/:id
POST /v1/gates/:id/decisions
POST /v1/daemon-sessions
GET  /v1/daemon-sessions
GET  /v1/daemon-sessions/:id
POST /v1/daemon-sessions/:id/heartbeat
```

All `/v1/*` endpoints require `Authorization: Bearer <token>`.

## Where this document does not go

The following are intentionally not specified here:

- Wire-level pagination cursors and rate-limit headers — defer to Phase 4.
- Internal storage layout (table partitioning, archival rules) — defer
  to operator preference at deploy time.
- Multi-region or HA topology — single replica is acceptable for v0.
- Federation between coordinators — a future doc.

## Cross-references

- `docs/coordination-modes.md` — where the coordinator fits in.
- `docs/daemon-join-protocol.md` — how a daemon connects.
- `docs/team-mode-security.md` — trust model and minimization rules.
- `docs/local-state-plane.md` — what stays in `.sykli/` vs the coordinator.
- `docs/team-mode-roadmap.md` — phased implementation plan.
- `docs/error-codes.md` — public error code catalog.
- `docs/false-protocol-schema.md` — local on-disk schema for evidence.
