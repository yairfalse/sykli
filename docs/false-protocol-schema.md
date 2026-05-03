# FALSE Protocol And `.sykli/` Schema

This document describes the on-disk files that humans, agents, MCP tools, and downstream automation read from `.sykli/`. These shapes are the machine surface of sykli and should be treated with the same care as CLI output.

Stability tiers match `docs/error-codes.md`:

- **public-stable**: agents may depend on the field across minor releases.
- **public-unstable**: exposed, but still allowed to change during the current feature line.
- **internal**: persisted for sykli implementation details; do not build external contracts on it.

The samples below were generated from existing fixtures:

```sh
tmp=$(mktemp -d)
cp test/blackbox/fixtures/single_task.exs "$tmp/sykli.exs"
cd "$tmp"
/Users/yair/projects/sykli/core/sykli run
/Users/yair/projects/sykli/core/sykli context
```

The attestation sample uses `test/blackbox/fixtures/failing_task.exs`, because failed terminal runs emit a run-level attestation even without artifact outputs.

## `.sykli/occurrence.json`

Producer: `Sykli.Occurrence.Enrichment` through `Sykli.Occurrence.Store`.

Stability: public-stable for top-level FALSE Protocol fields; public-unstable for type-specific `data` payloads; internal for archived ETF mirrors.

`occurrence.json` is the latest terminal FALSE Protocol occurrence. Archived JSON copies live in `.sykli/occurrences_json/<run_id>.json`; ETF copies live in `.sykli/occurrences/<run_id>.etf`.

Sample:

```json
{
  "context": {
    "labels": {
      "sykli.node": "nonode@nohost",
      "sykli.run_id": "01KQPFNW2N4MK5KMJKTSPJ5MG6"
    }
  },
  "data": {
    "git": {
      "branch": null,
      "changed_files": [],
      "recent_commits": [],
      "remote_url": null,
      "sha": null
    },
    "summary": {
      "cached": 0,
      "errored": 0,
      "failed": 0,
      "passed": 1,
      "skipped": 0
    },
    "tasks": [
      {
        "cached": false,
        "command": "echo hello",
        "duration_ms": 25,
        "log": ".sykli/logs/01KQPFNW2N4MK5KMJKTSPJ5MG6/hello.log",
        "name": "hello",
        "status": "passed"
      }
    ]
  },
  "history": {
    "duration_ms": 25,
    "steps": [
      {
        "action": "hello",
        "description": "echo hello",
        "duration_ms": 25,
        "outcome": "success",
        "timestamp": "2026-05-03T08:36:01.749155Z"
      }
    ]
  },
  "id": "01KQPFNW2QPNS3HH6YR5AX25Y8",
  "outcome": "success",
  "protocol_version": "1.0",
  "severity": "info",
  "source": "sykli",
  "timestamp": "2026-05-03T08:36:01.749155Z",
  "type": "ci.run.passed"
}
```

Fields:

| Field | Type | Required | Stability | Semantics |
|-------|------|----------|-----------|-----------|
| `id` | string | yes | public-stable | ULID-like occurrence identifier. Distinct from `run_id`. |
| `type` | string | yes | public-stable | FALSE Protocol event type. Current families include `ci.run.*`, `ci.task.*`, `ci.cache.*`, `ci.gate.*`, and `ci.github.*`. |
| `timestamp` | string | yes | public-stable | ISO-8601 event timestamp. |
| `source` | string | yes | public-stable | Event source, default `sykli` unless configured. |
| `protocol_version` | string | yes | public-stable | FALSE Protocol version. Current value is `"1.0"`. |
| `severity` | string | yes | public-stable | Human/agent severity such as `info` or `error`. |
| `outcome` | string | terminal events | public-stable | Terminal outcome such as `success` or `failure`. |
| `context.labels` | object | yes | public-stable | Correlation labels. Includes `sykli.run_id` and node label when available. |
| `data.git` | object | terminal events | public-unstable | Git branch, SHA, remote, changed files, and recent commits. Values may be `null` outside Git repos. |
| `data.summary` | object | terminal events | public-stable | Count of task statuses: `passed`, `failed`, `errored`, `cached`, `skipped`. |
| `data.tasks` | array | terminal events | public-stable | Per-task status records. Each item has `name`, `status`, `cached`, `duration_ms`, optional `command`, optional `log`, optional `error`. |
| `error` | object | failed terminal events | public-stable | Top-level failure summary with stable `code`, `message`, and `what_failed`. |
| `reasoning` | object | failed terminal events | public-unstable | Heuristic explanation block with `summary`, `explanation`, and `confidence`. |
| `history` | object | terminal events | public-stable | Ordered execution steps with action, outcome, timestamp, duration, and optional error. |

## `.sykli/attestation.json` And `.sykli/attestations/*`

Producer: `Sykli.Attestation`, wrapped by `Sykli.Attestation.Envelope` from `Sykli.Occurrence.Enrichment`.

Stability: public-unstable. The DSSE envelope shape is stable; exact SLSA predicate details may evolve with provenance support.

`attestation.json` is the run-level DSSE envelope. `.sykli/attestations/<task>.json` uses the same envelope shape for per-task attestations when tasks declare outputs and those outputs have cached digests.

Sample DSSE envelope:

```json
{
  "payload": "eyJfdHlwZSI6Imh0dHBzOi8vaW4tdG90by5pby9TdGF0ZW1lbnQvdjEiLCJwcmVkaWNhdGUiOnsiYnVpbGREZWZpbml0aW9uIjp7ImJ1aWxkVHlwZSI6Imh0dHBzOi8vc3lrbGkuZGV2L1N5a2xpVGFzay92MSIsImV4dGVybmFsUGFyYW1ldGVycyI6eyJ0YXNrcyI6W3siY29tbWFuZCI6ImV4aXQgMSIsIm5hbWUiOiJiYWQifV19LCJpbnRlcm5hbFBhcmFtZXRlcnMiOnsicnVuX2lkIjoiMDFLUVBGUjFLWUpLMjhHVzVCMVRTQVpFUjEiLCJzb3VyY2UiOiJzeWtsaSJ9fSwicnVuRGV0YWlscyI6eyJidWlsZGVyIjp7ImlkIjoiaHR0cHM6Ly9zeWtsaS5kZXYvYnVpbGRlci92MSIsInZlcnNpb24iOnsic3lrbGkiOiIwLjYuMCJ9fSwibWV0YWRhdGEiOnsiZmluaXNoZWRPbiI6IjIwMjYtMDUtMDNUMDg6Mzc6MTIuOTgzMzYyWiIsImludm9jYXRpb25JZCI6IjAxS1FQRlIxS1lKSzI4R1c1QjFUU0FaRVIxIiwib3V0Y29tZSI6ImZhaWx1cmUiLCJzdGFydGVkT24iOiIyMDI2LTA1LTAzVDA4OjM3OjEyLjk1ODM2MloifX19LCJwcmVkaWNhdGVUeXBlIjoiaHR0cHM6Ly9zbHNhLmRldi9wcm92ZW5hbmNlL3YxIiwic3ViamVjdCI6W119",
  "payloadType": "application/vnd.in-toto+json",
  "signatures": []
}
```

Decoded payload:

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "predicateType": "https://slsa.dev/provenance/v1",
  "subject": [],
  "predicate": {
    "buildDefinition": {
      "buildType": "https://sykli.dev/SykliTask/v1",
      "externalParameters": {
        "tasks": [
          {
            "command": "exit 1",
            "name": "bad"
          }
        ]
      },
      "internalParameters": {
        "run_id": "01KQPFR1KYJK28GW5B1TSAZER1",
        "source": "sykli"
      }
    },
    "runDetails": {
      "builder": {
        "id": "https://sykli.dev/builder/v1",
        "version": {
          "sykli": "0.6.0"
        }
      },
      "metadata": {
        "finishedOn": "2026-05-03T08:37:12.983362Z",
        "invocationId": "01KQPFR1KYJK28GW5B1TSAZER1",
        "outcome": "failure",
        "startedOn": "2026-05-03T08:37:12.958362Z"
      }
    }
  }
}
```

Fields:

| Field | Type | Required | Stability | Semantics |
|-------|------|----------|-----------|-----------|
| `payloadType` | string | yes | public-stable | DSSE payload type. Current value is `application/vnd.in-toto+json`. |
| `payload` | string | yes | public-stable | Base64-encoded in-toto statement. |
| `signatures` | array | yes | public-stable | DSSE signatures. Empty when no signing key is configured. |
| decoded `_type` | string | yes | public-stable | in-toto statement type. |
| decoded `predicateType` | string | yes | public-stable | SLSA provenance predicate type. |
| decoded `subject` | array | yes | public-stable | Artifact subjects with SHA256 digests. Empty for failed runs without outputs. |
| decoded `predicate.buildDefinition` | object | yes | public-unstable | Build type plus external task parameters and internal sykli run parameters. |
| decoded `predicate.runDetails` | object | yes | public-unstable | Builder identity, version, invocation ID, timestamps, and outcome. |

## `.sykli/runs/*`

Producer: `Sykli.RunHistory`.

Stability: public-unstable. This file is intended for `sykli history`, `sykli report`, `sykli query`, and agents, but the history model is still expanding.

Each file is a per-run manifest. Filename is the run timestamp with characters made filesystem-safe.

Sample:

```json
{
  "id": "01KQPFNW2N4MK5KMJKTSPJ5MG6",
  "timestamp": "2026-05-03T08:36:01.749155Z",
  "overall": "passed",
  "tasks": [
    {
      "name": "hello",
      "status": "passed",
      "cached": false,
      "duration_ms": 25,
      "streak": 1,
      "inputs": []
    }
  ],
  "git_ref": "unknown",
  "git_branch": "unknown"
}
```

Fields:

| Field | Type | Required | Stability | Semantics |
|-------|------|----------|-----------|-----------|
| `id` | string | yes | public-stable | Run ID. |
| `timestamp` | string | yes | public-stable | Terminal run timestamp. |
| `overall` | string | yes | public-stable | Run status, usually `passed` or `failed`. |
| `tasks` | array | yes | public-stable | Per-task history records. |
| `tasks[].name` | string | yes | public-stable | Task name. |
| `tasks[].status` | string | yes | public-stable | TaskResult status as a string. |
| `tasks[].cached` | boolean | yes | public-stable | Whether the task result came from cache. |
| `tasks[].duration_ms` | integer | no | public-unstable | Task duration in milliseconds when known. |
| `tasks[].streak` | integer | no | public-unstable | Consecutive pass/fail streak used by history analysis. |
| `tasks[].inputs` | array | yes | public-unstable | Input paths contributing to task history. |
| `tasks[].error` | string | failed tasks | public-stable | Compact `code: message` failure string. |
| `git_ref` | string | yes | public-unstable | Git ref or `unknown`. |
| `git_branch` | string | yes | public-unstable | Git branch or `unknown`. |

## `.sykli/context.json`

Producer: `Sykli.Context.generate/3`, exposed through `sykli context`.

Stability: public-stable for top-level sections and task basics; public-unstable for health and coverage details.

Sample:

```json
{
  "coverage": {
    "file_to_tasks": {},
    "uncovered_patterns": []
  },
  "generated_at": "2026-05-03T08:36:05.302048Z",
  "health": {
    "avg_duration_ms": 25,
    "flaky_tasks": [],
    "last_success": "2026-05-03T08:36:01.749155Z",
    "recent_runs": 1,
    "success_rate": 1.0
  },
  "last_run": {
    "duration_ms": 25,
    "outcome": "success",
    "tasks": [
      {
        "cached": false,
        "duration_ms": 25,
        "name": "hello",
        "status": "passed"
      }
    ],
    "timestamp": "2026-05-03T08:36:01.749155Z"
  },
  "pipeline": {
    "critical_tasks": [],
    "dependencies": {
      "hello": []
    },
    "estimated_duration_ms": 1000,
    "parallelism": 1,
    "task_count": 1,
    "tasks": [
      {
        "command": "echo hello",
        "depends_on": [],
        "name": "hello"
      }
    ]
  },
  "project": {
    "languages": [],
    "name": "sykli-schema.BdLCod",
    "path": "/private/tmp/sykli-schema.BdLCod",
    "sdk": "elixir"
  },
  "version": "1.0"
}
```

Fields:

| Field | Type | Required | Stability | Semantics |
|-------|------|----------|-----------|-----------|
| `version` | string | yes | public-stable | Context schema version. |
| `generated_at` | string | yes | public-stable | ISO-8601 generation timestamp. |
| `project` | object | yes | public-stable | Project name, path, detected languages, and SDK. |
| `pipeline` | object | yes | public-stable | Static graph summary: task count, tasks, dependencies, critical tasks, parallelism, estimated duration. |
| `pipeline.tasks[]` | array | yes | public-stable | Task basics with `name`, `command`, and `depends_on`; may include semantic metadata for richer SDK definitions. |
| `coverage` | object | yes | public-unstable | File-to-task coverage map and uncovered patterns. |
| `health` | object | no | public-unstable | Recent run aggregate health: success rate, average duration, flaky tasks, last success. |
| `last_run` | object | no | public-stable | Latest run summary if history exists. |

## `.sykli/test-map.json`

Producer: `Sykli.Context.generate_test_map/2`.

Stability: public-unstable. The producer exists today; the main CLI `sykli context` embeds coverage in `context.json` and does not currently write this file by default.

Sample:

```json
{}
```

Fields:

| Field | Type | Required | Stability | Semantics |
|-------|------|----------|-----------|-----------|
| top-level object | object | yes | public-unstable | Keys are source file paths or glob-like coverage patterns; values are arrays of task names that cover that path. Empty object means no semantic `covers` metadata was declared. |
| `<path>` | string key | no | public-unstable | File path or coverage pattern from task semantic metadata. |
| `<path>[]` | array of strings | no | public-stable | Task names that should be considered relevant for that file. |
