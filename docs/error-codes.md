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

### execution

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `missing_secrets` | A task requires secrets that are not present in the execution environment. | public-stable | `core/lib/sykli/error.ex:181` |
| `success_criteria_failed` | A task command succeeded, but one or more declared success criteria failed. | public-unstable | `core/lib/sykli/error.ex:183` |
| `task_failed` | A task command exited non-zero; this is a content failure, not infrastructure failure. | public-stable | `core/lib/sykli/error.ex:137` |
| `task_timeout` | A task exceeded its configured timeout. | public-stable | `core/lib/sykli/error.ex:159` |
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
| `unknown` | JSON envelope fallback when an error-like value is not a `Sykli.Error`. | internal | `core/lib/sykli/cli/json_response.ex:51`, `core/lib/sykli/cli.ex:317` |

### runtime

| Code | Description | Tier | Emitted from |
|------|-------------|------|--------------|
| `cluster_unreachable` | Kubernetes target setup could not connect to the configured cluster. | public-stable | `core/lib/sykli/error.ex:451` |
| `docker_not_running` | Docker runtime setup could not reach a usable Docker daemon. | public-stable | `core/lib/sykli/error.ex:415` |
| `image_not_found` | A requested container image was not available to the runtime. | public-stable | `core/lib/sykli/error.ex:432` |
| `not_a_git_repo` | A target path that requires Git metadata is not inside a Git repository. | public-stable | `core/lib/sykli/error.ex:486` |
| `resource_failed` | Kubernetes target setup could not create a required cluster resource. | public-stable | `core/lib/sykli/error.ex:468` |
| `uncommitted_changes` | A target requires reproducible Git state, but the working tree has uncommitted changes. | public-stable | `core/lib/sykli/error.ex:503` |

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
