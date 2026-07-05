# Sykli Error Codes

Sykli error codes are part of the agent-facing contract. Humans read the message and hints; agents may pattern-match the code to decide whether to retry, ask for credentials, run `sykli fix`, or stop.

## Policy

Add a code whenever a `%Sykli.Error{}` can cross a public boundary: CLI JSON output, MCP responses, FALSE Protocol occurrences, GitHub Checks output, or persisted `.sykli/` artifacts. New codes use `<domain>.<verb_phrase>` such as `github.webhook.bad_signature`. Legacy underscore codes are grandfathered until a migration window exists.

Use these stability tiers:

- **public-stable** — exposed to users or agents as a documented contract. Changing or removing it requires a major version bump and a CHANGELOG migration note.
- **public-unstable** — exposed externally, but attached to a young surface that may still change between minor versions. Agents can inspect it, but should not rely on it indefinitely.
- **internal** — implementation detail used for logs, setup failures, tests, or defensive wrapping. It may change without notice.

To rename or deprecate a public code, add the replacement first, keep the old code for at least one minor release line, document both in `CHANGELOG.md`, and update this catalog. Do not silently repurpose an existing code for a new failure class.

## Catalog

### cache

No cache-prefixed `Sykli.Error` codes are emitted today. Cache failures currently surface through execution/runtime errors or internal wrapping.

### audit

Audit codes are public-unstable while `sykli audit` is new.

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `audit.run_not_found` | `sykli audit` was called without a run id, or the requested run id is not present in local run history. | public-unstable | `core/lib/sykli/cli/audit.ex` |
| `audit.invalid_args` | `sykli audit` received an unsupported argument shape. | public-unstable | `core/lib/sykli/cli/audit.ex` |
| `audit.history_corrupt` | The run manifest recording the requested run id exists in `.sykli/runs/` but cannot be decoded. | public-unstable | `core/lib/sykli/cli/audit.ex` |

### contract

Contract codes are public-stable because they are emitted by `sykli lock`,
`sykli validate`, and `sykli run` JSON surfaces.

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `contract.lock_mismatch` | The emitted contract hash does not match `sykli.lock`. | public-stable | `core/lib/sykli/contract_lock.ex` |
| `contract.lock_corrupt` | `sykli.lock` is unreadable, malformed, missing required fields, or has an invalid internal hash. | public-stable | `core/lib/sykli/contract_lock.ex` |
| `contract.nondeterministic` | Two emissions of the same pipeline produced different canonical hashes. | public-stable | `core/lib/sykli/contract_lock.ex` |

### coordinator

Coordinator codes are public-unstable while the self-hosted Team Mode API
surface is still young. They are emitted in the JSON envelope returned by
`sykli coordinator start` and by the coordinator HTTP API.

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `coordinator.auth_not_configured` | The coordinator API was started without an auth token configuration for protected endpoints. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:182` |
| `coordinator.body_read_failed` | Plug failed to read the coordinator request body. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:194` |
| `coordinator.duplicate_org_slug` | An org create request used an org slug that already exists. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:206` |
| `coordinator.duplicate_team_slug` | A team create request used a team slug that already exists in the org. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:209` |
| `coordinator.forbidden` | A valid coordinator token attempted to access or mutate a resource outside its authorized team scope. | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `coordinator.daemon_session_not_found` | A daemon session lookup or heartbeat referenced a session that does not exist. | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `coordinator.internal_error` | Fallback coordinator API error for an unexpected structured reason. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:227` |
| `coordinator.invalid_assignment_type` | A work claim request used an unsupported assignment type. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:221` |
| `coordinator.invalid_bind` | The coordinator CLI received an invalid `--bind` address. | public-unstable | `core/lib/sykli/cli/coordinator.ex:190` |
| `coordinator.invalid_command` | The coordinator CLI received an unsupported command or flag. | public-unstable | `core/lib/sykli/cli/coordinator.ex:200`, `core/lib/sykli/cli/coordinator.ex:210` |
| `coordinator.invalid_daemon_id` | A daemon join request used an invalid daemon id. | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `coordinator.invalid_daemon_payload` | A daemon join or heartbeat request used malformed labels, capabilities, or list fields. | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `coordinator.invalid_daemon_session_id` | A heartbeat or daemon-session lookup used an invalid session id. | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `coordinator.invalid_daemon_status` | A heartbeat request used an unsupported daemon status. | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `coordinator.invalid_json` | The coordinator request body was not valid JSON. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:185` |
| `coordinator.invalid_payload` | The coordinator request body was not an object or missed required fields. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:188`, `core/lib/sykli/team_coordinator/router.ex:200`, `core/lib/sykli/team_coordinator/router.ex:203` |
| `coordinator.invalid_port` | The coordinator CLI received an invalid `--port` value. | public-unstable | `core/lib/sykli/cli/coordinator.ex:180` |
| `coordinator.not_found` | The coordinator API endpoint path is not implemented. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:197` |
| `coordinator.org_not_found` | A coordinator request referenced an org that does not exist. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:212` |
| `coordinator.payload_too_large` | The coordinator request body exceeded the configured size limit. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:191` |
| `coordinator.start_failed` | The coordinator CLI could not start the HTTP service. | public-unstable | `core/lib/sykli/cli/coordinator.ex:220`, `core/lib/sykli/cli/coordinator.ex:231` |
| `coordinator.team_not_found` | A coordinator request referenced a team that does not exist. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:215` |
| `coordinator.token_required` | `sykli coordinator start` was called without `--token` or `SYKLI_COORDINATOR_TOKEN`. | public-unstable | `core/lib/sykli/cli/coordinator.ex:170` |
| `coordinator.unauthorized` | A protected coordinator endpoint was called without a valid bearer token. | public-unstable | `core/lib/sykli/team_coordinator/router.ex:176`, `core/lib/sykli/team_coordinator/router.ex:179` |

### daemon

Daemon Team Mode codes are public-unstable while daemon join/session
behavior is new. They are emitted by `sykli daemon join --json` and
daemon status/session JSON surfaces.

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `daemon.coordinator_error` | The coordinator rejected daemon join with a structured non-auth error. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.coordinator_unauthorized` | The coordinator rejected daemon join authorization. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.coordinator_unavailable` | The daemon join client could not reach the coordinator. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.invalid_coordinator_response` | The coordinator returned invalid JSON or an unexpected response shape. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.invalid_id` | `sykli daemon join` received or inferred an invalid daemon id. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.invalid_join_command` | `sykli daemon join` received an unsupported command form or flag. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.invalid_join_payload` | `sykli daemon join` received malformed label or capability arguments. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.join_failed` | Fallback daemon join failure for unexpected structured reasons. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.join_missing_coordinator` | `sykli daemon join` was called without `--coordinator`. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.join_missing_org` | `sykli daemon join` was called without `--org`. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.join_missing_team` | `sykli daemon join` was called without `--team`. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.join_missing_token` | `sykli daemon join` was called without `--token` or `SYKLI_TEAM_TOKEN`. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `daemon.stay_failed` | `sykli daemon join --stay` could not start the foreground heartbeat loop. | public-unstable | `core/lib/sykli/daemon/join.ex` |
| `gate.invalid_payload` | Coordinator gate publish payload failed validation. | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `gate.invalid_decision` | Coordinator gate decision payload failed validation. | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `gate.invalid_session` | Coordinator daemon-session record is missing team metadata (server-side data corruption, not an authz failure). | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `gate.unknown_session` | Gate publish referenced a daemon session the coordinator does not know. | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `gate.team_mismatch` | Gate publish or decision claimed a team the daemon session does not belong to. | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `gate.terminal` | Gate decision attempted on a gate already in a terminal status. | public-unstable | `core/lib/sykli/team_coordinator/router.ex` |
| `daemon.invalid_leave_command` | `sykli daemon leave` received an unsupported flag or command form. | public-unstable | `core/lib/sykli/daemon/leave.ex` |
| `daemon.leave_failed` | `sykli daemon leave` could not remove the local session file. | public-unstable | `core/lib/sykli/daemon/leave.ex` |

### team.run

Run summary sync codes are emitted by the coordinator run-summary API and
daemon-side deferred publish path.

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `team.run.publish_unauthorized` | The coordinator rejected run summary publish authorization. | public-unstable | `core/lib/sykli/error.ex` |
| `team.run.publish_unavailable` | The daemon could not reach the coordinator while publishing a run summary. | public-unstable | `core/lib/sykli/error.ex` |
| `team.run.invalid_payload` | A run summary request body was malformed or missed required fields. | public-stable | `core/lib/sykli/team_coordinator/router.ex` |
| `team.run.body_too_large` | A run summary request body exceeded the coordinator limit. | public-stable | `core/lib/sykli/team_coordinator/router.ex` |

### team.outbox

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `team.outbox.write_failed` | The daemon could not write a deferred Team Mode sync payload. | public-unstable | `core/lib/sykli/error.ex` |
| `team.outbox.invalid_kind` | Defensive guard for an invalid outbox kind. | internal | `core/lib/sykli/error.ex` |

### execution

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `mandate_violation` | A task ran but broke its declared v5 mandate (scope or budget); the recorded `mandate_outcome` is `violated` and `failure_semantics.reason` names the dimension (`mandate_scope_violation`, `mandate_budget_exceeded`). | public-unstable | `core/lib/sykli/error.ex` |
| `mandate_unsupported` | The target, runtime, or workdir cannot enforce a declared mandate dimension (`mandate_unsupported_target`, `mandate_requires_git`, `mandate_network_unsupported`); the task fails before running with outcome `unsupported`. | public-unstable | `core/lib/sykli/error.ex` |
| `mandate_verification_failed` | Mandate verification could not inspect the git work tree (git failed or timed out); enforcement fails closed with outcome `unverified` rather than reporting `kept`. | public-unstable | `core/lib/sykli/error.ex` |
| `missing_secrets` | A task requires secrets that are not present in the execution environment. | public-stable | `core/lib/sykli/error.ex:181` |
| `missing_evidence` | A task command and criteria passed, but one or more required evidence references were absent or unsatisfied. | public-unstable | `core/lib/sykli/error.ex` |
| `review_primitive_failed` | A review primitive failed, errored, or was unsupported. | public-unstable | `core/lib/sykli/error.ex` |
| `success_criteria_failed` | A task command succeeded, but one or more declared success criteria failed. | public-unstable | `core/lib/sykli/error.ex:183` |
| `task_failed` | A task command exited non-zero; this is a content failure, not infrastructure failure. | public-stable | `core/lib/sykli/error.ex:137` |
| `task_timeout` | A task exceeded its configured timeout. | public-stable | `core/lib/sykli/error.ex:159` |
| `unsupported_evidence_requirement_for_target` | The active target or runtime cannot evaluate one or more declared evidence requirements. | public-unstable | `core/lib/sykli/error.ex` |
| `unsupported_success_criteria_for_target` | The active target or runtime cannot evaluate one or more declared success criteria. | public-unstable | `core/lib/sykli/error.ex:203` |

### github.app

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `github.app.bad_response` | GitHub returned an installation-token response that could not be decoded into the expected token and expiry shape. | public-unstable | `core/lib/sykli/github/app/real.ex:117` |
| `github.app.jwt_failed` | Sykli could not sign the GitHub App JWT with the configured private key. | public-unstable | `core/lib/sykli/github/app/real.ex:46`, `core/lib/sykli/github/app/real.ex:49` |
| `github.app.missing_config` | Required GitHub App configuration is missing, usually `SYKLI_GITHUB_APP_ID` or `SYKLI_GITHUB_APP_PRIVATE_KEY`. | public-unstable | `core/lib/sykli/github/app/real.ex:127`, `core/lib/sykli/github/app/real.ex:130`, `core/lib/sykli/github/app/real.ex:141`, `core/lib/sykli/github/app/real.ex:145` |
| `github.app.private_key_not_found` | The configured GitHub App private-key path does not exist and the value is not a PEM literal. | public-unstable | `core/lib/sykli/github/app/real.ex:162` |
| `github.app.unauthorized` | GitHub rejected or could not service the installation-token request. | public-unstable | `core/lib/sykli/github/app/real.ex:92`, `core/lib/sykli/github/app/real.ex:100` |

### github.checks

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `github.checks.bad_response` | GitHub Checks API returned a response body that was not valid JSON. | public-unstable | `core/lib/sykli/github/checks/real.ex:91` |
| `github.checks.write_failed` | Sykli failed to create or update a GitHub check suite or check run. | public-unstable | `core/lib/sykli/github/checks/real.ex:18`, `core/lib/sykli/github/checks/real.ex:32`, `core/lib/sykli/github/checks/real.ex:44` |

### github.dispatch

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `github.dispatch.executor_failed` | GitHub-native dispatch reached the executor, but executor orchestration failed before producing task results. | public-unstable | `core/lib/sykli/github/dispatcher.ex:225` |
| `github.dispatch.failed` | Generic GitHub-native dispatch failure wrapper for unexpected dispatch errors. | public-unstable | `core/lib/sykli/github/dispatcher.ex:48`, `core/lib/sykli/github/dispatcher.ex:80` |
| `github.dispatch.graph_failed` | The cloned source contained a pipeline candidate, but Sykli could not emit or parse it into a graph. | public-unstable | `core/lib/sykli/github/dispatcher.ex:161` |
| `github.dispatch.no_pipeline` | No `sykli.*` pipeline file was found in the cloned GitHub source. | public-unstable | `core/lib/sykli/github/dispatcher.ex:155` |

### github.source

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `github.source.checkout_failed` | Source clone succeeded, but Sykli could not check out or fetch the webhook head SHA. | public-unstable | `core/lib/sykli/github/source/real.ex:88` |
| `github.source.clone_failed` | Sykli could not clone the GitHub repository for webhook-triggered execution. | public-unstable | `core/lib/sykli/github/source/real.ex:62`, `core/lib/sykli/github/source/real.ex:33` |
| `github.source.copy_failed` | Test-only fixture source acquisition failed while copying a fixture tree. | internal | `core/lib/sykli/github/source/fake.ex:46` |
| `github.source.path_escape` | Source acquisition resolved a path outside the allowed temporary run directory. | public-unstable | `core/lib/sykli/github/source/real.ex:156` |

### github.webhook

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `github.webhook.bad_signature` | The `X-Hub-Signature-256` HMAC did not match the raw webhook body. | public-unstable | `core/lib/sykli/github/webhook/receiver.ex:149` |
| `github.webhook.body_read_failed` | Plug failed to read the webhook request body, usually due to timeout or transport IO failure. | public-unstable | `core/lib/sykli/github/webhook/receiver.ex:111` |
| `github.webhook.body_too_large` | The webhook request body exceeded the configured receiver limit. | public-unstable | `core/lib/sykli/github/webhook/receiver.ex:104` |
| `github.webhook.dispatch_failed` | The receiver accepted the webhook but could not start the async dispatcher task. | public-unstable | `core/lib/sykli/github/webhook/receiver.ex:247` |
| `github.webhook.invalid_json` | The webhook body was not valid JSON. | public-unstable | `core/lib/sykli/github/webhook/receiver.ex:185` |
| `github.webhook.missing_delivery` | The webhook request did not include `X-GitHub-Delivery`. | public-unstable | `core/lib/sykli/github/webhook/receiver.ex:173` |
| `github.webhook.missing_secret` | The receiver has no configured webhook secret and cannot verify signatures. | public-unstable | `core/lib/sykli/github/webhook/receiver.ex:135` |
| `github.webhook.missing_signature` | The webhook request did not include `X-Hub-Signature-256`. | public-unstable | `core/lib/sykli/github/webhook/receiver.ex:140` |
| `github.webhook.replay` | The webhook delivery ID was already accepted by the replay cache. | public-unstable | `core/lib/sykli/github/webhook/receiver.ex:169` |
| `github.webhook.unsupported_payload` | The webhook payload lacks the repository, installation, or head SHA needed for dispatch. | public-unstable | `core/lib/sykli/github/webhook/receiver.ex:210` |
| `github.webhook.upstream_failure` | Fallback response code for an unexpected receiver failure outside structured webhook errors. | public-unstable | `core/lib/sykli/github/webhook/receiver.ex:86` |

### internal

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `internal_error` | Catch-all wrapper for unexpected Sykli failures. | public-stable | `core/lib/sykli/error.ex:540` |
| `source_not_found` / `source_not_regular` / `symlink_not_allowed` | Internal artifact-copy reasons returned by local target storage; callers should format or wrap them before exposing a public boundary. | internal | `core/lib/sykli/target/local.ex`, `core/lib/sykli/target/storage.ex` |
| `unknown` | JSON envelope fallback when an error-like value is not a `Sykli.Error`. | internal | `core/lib/sykli/cli/json_response.ex:51`, `core/lib/sykli/cli.ex:317` |

### mcp

MCP tool-dispatch codes are public-unstable while the agent tool surface
stabilizes. They originate inside `Sykli.MCP.Tools`, not the engine, and are
rendered through the shared `Sykli.CLI.JsonResponse` envelope (with
`isError: true`) so agents branch on `error.code` instead of parsing prose.

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `mcp.unknown_tool` | An MCP `tools/call` named a tool that does not exist. | public-unstable | `core/lib/sykli/error.ex` |
| `mcp.no_occurrence` | A tool needs occurrence data but no run has been recorded for the project yet. | public-unstable | `core/lib/sykli/error.ex` |
| `mcp.missing_argument` | A required tool argument was absent or empty. | public-unstable | `core/lib/sykli/error.ex` |
| `mcp.tool_crashed` | A tool raised an unexpected exception during dispatch. | public-unstable | `core/lib/sykli/error.ex` |
| `graph.invalid_contract` | A graph contract violation surfaced while parsing the pipeline for a read-only MCP tool (e.g. `task_type` on a review node). | public-unstable | `core/lib/sykli/mcp/tools.ex` |

### runtime

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `cluster_unreachable` | Kubernetes target setup could not connect to the configured cluster. | public-stable | `core/lib/sykli/error.ex:451` |
| `docker_not_running` | Docker runtime setup could not reach a usable Docker daemon. | public-stable | `core/lib/sykli/error.ex:415` |
| `image_not_found` | A requested container image was not available to the runtime. | public-stable | `core/lib/sykli/error.ex:432` |
| `not_a_git_repo` | A target path that requires Git metadata is not inside a Git repository. | public-stable | `core/lib/sykli/error.ex:486` |
| `resource_failed` | Kubernetes target setup could not create a required cluster resource. | public-stable | `core/lib/sykli/error.ex:468` |
| `uncommitted_changes` | A target requires reproducible Git state, but the working tree has uncommitted changes. | public-stable | `core/lib/sykli/error.ex:503` |

### work

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `contract_hash_failed` | Sykli could not canonicalize emitted contract JSON to compute a local work/run contract hash. | public-unstable | `core/lib/sykli/error.ex:664` |
| `invalid_work_item` | A local work item command encountered structurally invalid work item data or arguments. | public-unstable | `core/lib/sykli/error.ex:654` |
| `invalid_work_item_id` | A local work item id failed validation, including path traversal attempts. | public-unstable | `core/lib/sykli/error.ex:622` |
| `malformed_work_item_json` | A persisted `.sykli/work/items/<id>.json` file is not valid JSON. | public-unstable | `core/lib/sykli/error.ex:643` |
| `work.team_coordinator_error` | The coordinator rejected a team work command with a structured non-auth error. | public-unstable | `core/lib/sykli/cli/work.ex` |
| `work.team_coordinator_unavailable` | A team work command could not reach the joined coordinator. | public-unstable | `core/lib/sykli/cli/work.ex` |
| `work.team_invalid_coordinator_response` | The coordinator returned invalid JSON or an unexpected response shape for a team work command. | public-unstable | `core/lib/sykli/cli/work.ex` |
| `work.team_mismatch` | A team work command requested a team other than the joined coordinator team. | public-unstable | `core/lib/sykli/cli/work.ex` |
| `work.team_missing_token` | A team work command was run without `SYKLI_TEAM_TOKEN`. | public-unstable | `core/lib/sykli/cli/work.ex` |
| `work.team_not_joined` | A team work command was run before `sykli daemon join` created a local coordinator session. | public-unstable | `core/lib/sykli/cli/work.ex` |
| `work.team_required` | Team mode was selected without a team name. | public-unstable | `core/lib/sykli/cli/work.ex` |
| `work.team_runs_not_supported` | `sykli work runs --team` was requested before run summary sync exists. | public-unstable | `core/lib/sykli/cli/work.ex` |
| `work.team_session_invalid` | The local daemon coordinator session file is malformed or invalid. | public-unstable | `core/lib/sykli/cli/work.ex` |
| `work.team_unauthorized` | The coordinator rejected authorization for a team work command. | public-unstable | `core/lib/sykli/cli/work.ex` |
| `work_item_already_claimed` | A local work item claim was rejected because the item is no longer open. | public-unstable | `core/lib/sykli/error.ex:632` |
| `work_item_missing_title` | `sykli work create` was called without a title. | public-unstable | `core/lib/sykli/error.ex:602` |
| `work_item_not_found` | A requested local work item does not exist. | public-unstable | `core/lib/sykli/error.ex:612` |

### gates

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `gate_decision_missing_reason` | `sykli gate approve` or `sykli gate reject` was called without a non-empty reason. | public-unstable | `core/lib/sykli/error.ex:719` |
| `gate_not_found` | A requested local gate does not exist. | public-unstable | `core/lib/sykli/error.ex:678` |
| `invalid_gate_decision` | A local gate command encountered structurally invalid gate data or arguments. | public-unstable | `core/lib/sykli/error.ex:729` |
| `invalid_gate_id` | A local gate id failed validation, including path traversal attempts. | public-unstable | `core/lib/sykli/error.ex:688` |
| `invalid_gate_transition` | A terminal or otherwise invalid gate status transition was rejected. | public-unstable | `core/lib/sykli/error.ex:709` |
| `malformed_gate_json` | A persisted `.sykli/gates/<gate-id>.json` file is not valid JSON. | public-unstable | `core/lib/sykli/error.ex:698` |

### sdk

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `invalid_json` | An SDK emitter produced output that Sykli could not parse as a graph JSON document. | public-stable | `core/lib/sykli/error.ex:378` |
| `missing_tool` | The selected SDK requires a local tool that is not installed. | public-stable | `core/lib/sykli/error.ex:395` |
| `sdk_failed` | An SDK emitter failed before producing graph JSON. | public-stable | `core/lib/sykli/error.ex:340` |
| `sdk_not_found` | No supported `sykli.*` pipeline file was found. | public-stable | `core/lib/sykli/error.ex:311` |
| `sdk_timeout` | An SDK emitter exceeded its timeout. | public-stable | `core/lib/sykli/error.ex:358` |

### validation

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `dependency_cycle` | Graph validation found a circular dependency between tasks. | public-stable | `core/lib/sykli/error.ex:205` |
| `invalid_mount` | A graph mount declaration is missing required fields or uses an unsupported type. | public-stable | `core/lib/sykli/error.ex:255` |
| `invalid_service` | A graph service declaration is missing required fields such as name or image. | public-stable | `core/lib/sykli/error.ex:231` |
| `missing_artifact` | A task references an artifact output or producing task that the graph cannot satisfy. | public-stable | `core/lib/sykli/error.ex:293` |

### contract schema version validation

These are public parse/validation error types, not `%Sykli.Error{}` codes. They
can appear in `sykli validate --json`, parser/validator results, and MCP/tool
responses that surface graph parse failures.

| Type | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `empty_contract_schema_version` | The top-level `version` field is an empty or whitespace-only string. | public-stable | `core/lib/sykli/contract_schema_version.ex:37` |
| `invalid_contract_schema_version_type` | The top-level `version` field is present but is not a string. | public-stable | `core/lib/sykli/contract_schema_version.ex:48` |
| `missing_contract_schema_version` | The contract has no top-level `version` field. | public-stable | `core/lib/sykli/contract_schema_version.ex:30` |
| `unsupported_contract_schema_version` | The top-level `version` string is not one of the supported contract schema versions. | public-stable | `core/lib/sykli/contract_schema_version.ex:44` |
