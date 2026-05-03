# Sykli MCP Tools Audit

This is an audit of the current MCP protocol surface under `core/lib/sykli/mcp/`. It documents what agents can call today and where the surface is weaker than the dual-surface bar. This is audit-only: no new tools are introduced here.

Protocol notes:

- Transport: stdio with `Content-Length` framed JSON-RPC 2.0 messages.
- Lifecycle: `initialize`, `initialized`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`.
- Tool result shape: `tools/call` returns MCP `content` with one `text` item. Successful tool maps are JSON-encoded into that text field; errors are plain text with `isError: true`.
- JSON envelope: tools do **not** currently return the `Sykli.CLI.JsonResponse` envelope.

## Current Tools

| Tool | Description | Parameter schema | Return shape | Composability |
|------|-------------|------------------|--------------|---------------|
| `run_pipeline` | Execute the current pipeline and return task statuses, durations, cache flags, and errors. | `path` string optional, description quality: acceptable. `tasks` array of strings optional, description quality: acceptable. `timeout` integer optional, description quality: acceptable but unit is milliseconds and not constrained. | Structured map encoded as JSON text. Success shape has `status: "passed"` and `tasks`; failure-with-results shape has `status: "failed"` and `tasks`; infrastructure errors return plain rendered text. No JSON envelope. | Natural start of a chain into `get_failure`, `run_fix`, and `get_history`. Weak link: errors are not stable structured codes. |
| `explain_pipeline` | Describe pipeline structure, dependencies, execution levels, critical path, and semantic metadata without running tasks. | `path` string optional, description quality: acceptable. | Structured explanation map encoded as JSON text; errors are plain text. No JSON envelope. | Chains well before `run_pipeline` and `suggest_tests`. Also useful after SDK edits. |
| `get_failure` | Return the latest or selected failure occurrence with error context. | `path` string optional, description quality: acceptable. `run_id` string optional, description quality: acceptable but format is unconstrained. | Returns raw occurrence data as JSON text when found. Missing data returns plain text error. No JSON envelope. | Chains from `run_pipeline` failure into `run_fix`. It is a dead end for agents when no occurrence exists because the error is prose only. |
| `suggest_tests` | Suggest affected tasks for changed files using semantic coverage and dependency analysis. | `path` string optional, description quality: acceptable. `changed_files` array of strings optional, description quality: good. | Structured map encoded as JSON text with `changed_files`, `affected`, `skipped`, or a no-change `message`. No JSON envelope. | Chains naturally into `run_pipeline` by passing affected task names, but the return shape does not include a ready-to-call task list field. |
| `get_history` | Return recent run history and computed patterns. | `path` string optional, description quality: acceptable. `limit` integer optional, description quality: acceptable but no min/max. | Structured map encoded as JSON text with `runs` and `patterns`. No JSON envelope. | Useful after `run_pipeline` or `get_failure` to assess flakiness. Does not expose query filters, so agents must post-process. |
| `retry_task` | Re-run specific tasks by name. | `path` string optional, description quality: acceptable. `tasks` array of strings required, description quality: good but no `minItems`. | Structured map encoded as JSON text for task results; missing tasks returns plain text error. No JSON envelope. | Chains from `get_failure`, `suggest_tests`, or `explain_pipeline`. It partly duplicates `run_pipeline` with `tasks`, which may confuse agents. |
| `run_fix` | Analyze the last failure and return structured fix analysis. | `path` string optional, description quality: acceptable. `task` string optional, description quality: acceptable. | Structured fix-analysis map encoded as JSON text, or plain text errors for no occurrence. No JSON envelope. | Natural terminal step after `get_failure`. It should be one of the most important agent tools, but its error surface is prose-only. |

## Tool Details

### `run_pipeline`

Parameters:

| Name | Type | Required | Description quality | Notes |
|------|------|----------|---------------------|-------|
| `path` | string | no | acceptable | Defaults to current directory. Could specify path containment expectations. |
| `tasks` | array<string> | no | acceptable | Filters by task name. No schema-level `minItems`. |
| `timeout` | integer | no | acceptable | Milliseconds. No minimum or maximum. |

Return:

```json
{
  "status": "passed",
  "tasks": [
    {
      "name": "test",
      "status": "passed",
      "duration_ms": 42,
      "cached": false
    }
  ]
}
```

### `explain_pipeline`

Parameters:

| Name | Type | Required | Description quality | Notes |
|------|------|----------|---------------------|-------|
| `path` | string | no | acceptable | Defaults to current directory. |

Return: `Sykli.Explain.pipeline/2` map encoded as JSON text.

### `get_failure`

Parameters:

| Name | Type | Required | Description quality | Notes |
|------|------|----------|---------------------|-------|
| `path` | string | no | acceptable | Used only for cold `.sykli/occurrence.json` fallback. |
| `run_id` | string | no | acceptable | No pattern hint for valid run IDs. |

Return: raw occurrence JSON map encoded as text, or prose error.

### `suggest_tests`

Parameters:

| Name | Type | Required | Description quality | Notes |
|------|------|----------|---------------------|-------|
| `path` | string | no | acceptable | Defaults to current directory. |
| `changed_files` | array<string> | no | good | If omitted, the tool runs git diff against `HEAD`. |

Return:

```json
{
  "changed_files": ["lib/app.ex"],
  "affected": [
    {
      "name": "test",
      "reason": "input_changed",
      "files": ["lib/app.ex"],
      "depends_on": []
    }
  ],
  "skipped": []
}
```

### `get_history`

Parameters:

| Name | Type | Required | Description quality | Notes |
|------|------|----------|---------------------|-------|
| `path` | string | no | acceptable | Defaults to current directory. |
| `limit` | integer | no | acceptable | Defaults to 10. No upper bound in schema. |

Return:

```json
{
  "runs": [
    {
      "id": "01K...",
      "timestamp": "2026-05-03T08:36:01Z",
      "git_ref": "unknown",
      "git_branch": "unknown",
      "overall": "passed",
      "task_count": 1,
      "passed": 1,
      "failed": 0
    }
  ],
  "patterns": {
    "total_runs": 1,
    "success_rate": 1.0,
    "avg_duration_ms": 42,
    "flaky_tasks": []
  }
}
```

### `retry_task`

Parameters:

| Name | Type | Required | Description quality | Notes |
|------|------|----------|---------------------|-------|
| `path` | string | no | acceptable | Defaults to current directory. |
| `tasks` | array<string> | yes | good | Required, but schema does not enforce non-empty arrays. |

Return: structured retry result map encoded as JSON text, or prose error.

### `run_fix`

Parameters:

| Name | Type | Required | Description quality | Notes |
|------|------|----------|---------------------|-------|
| `path` | string | no | acceptable | Defaults to current directory. |
| `task` | string | no | acceptable | Restricts analysis to a named failed task. |

Return: `Sykli.Fix.analyze/2` map encoded as JSON text, or prose error.

## Gaps And Recommendations

1. **Return envelopes are inconsistent with the CLI agent contract.** MCP tools should return the `Sykli.CLI.JsonResponse` shape, or the MCP-specific reason for not doing so should be documented. Today success values are JSON text and errors are prose text.

2. **Error codes are missing from MCP failures.** Tool failures like "No occurrence data found" and "Unknown tool" should expose stable `Sykli.Error` codes so agents can branch without parsing prose.

3. **The tool list lacks `explain`, `query`, and richer history discovery parity.** `explain_pipeline` covers pipeline structure only; there is no direct MCP counterpart for `sykli query` grammar discovery or `sykli report`.

4. **Review primitives have no MCP surface yet.** Once review nodes ship, agents will need a read-only graph inspection tool and a controlled invocation tool for review primitive execution. Do not add it before the graph model lands.

5. **Schemas should tighten loose integers and arrays.** Add `minimum` for `timeout` and `limit`, `minItems` for required `tasks`, and enum-like constraints where a future parameter has known modes.

6. **`retry_task` duplicates `run_pipeline` filtering.** Consider either documenting `retry_task` as a convenience wrapper or folding it into a more general `run_pipeline` schema with a clear `mode`.

7. **`suggest_tests` should return a ready-to-call task list.** Add a `run_tasks` array so agents can pass it directly to `run_pipeline.tasks` without reconstructing from `affected`.

8. **Tool descriptions still say "CI pipeline".** ADR-022 reframes sykli as execution graphs as code. MCP descriptions should use graph language so agents do not treat non-CI nodes as unsupported.

9. **Module documentation says five tools, but seven are exposed.** Keep implementation docs aligned with `tools/list` so audits do not diverge from the actual protocol surface.

10. **Token efficiency is uneven.** `get_failure` returns the full occurrence by default. Add a terse default with an explicit verbose flag or field selector so agents do not pay for large logs unless they ask.
