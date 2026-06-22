# Sykli MCP Tools Audit

This is an audit of the current MCP protocol surface under `core/lib/sykli/mcp/`. It documents what agents can call today and where the surface is weaker than the dual-surface bar. This is audit-only: no new tools are introduced here.

Protocol notes:

- Transport: stdio with `Content-Length` framed JSON-RPC 2.0 messages.
- Lifecycle: `initialize`, `initialized`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`.
- Tool result shape: `tools/call` returns MCP `content` with one `text` item. The text is always a JSON string using the shared `Sykli.CLI.JsonResponse` envelope (`{ok, version, data, error}`); successful tool maps are under `data`, and failures set `isError: true` with a coded `error`.
- Typed result metadata: `run_pipeline`, `retry_task`, and `get_failure` task records may carry `failure_semantics`, `agent_hints`, `contract_slice`, `success_criteria_results`, and `evidence_results`. See `docs/failure-semantics.md`, `docs/agent-readable-failure-output.md`, and `docs/result-contract-slices.md`.

## Current Tools

| Tool | Description | Parameter schema | Return shape | Composability |
|------|-------------|------------------|--------------|---------------|
| `run_pipeline` | Execute the current graph and return task statuses, durations, cache flags, and errors. | `path` string optional, description quality: acceptable. `tasks` array of strings optional, description quality: acceptable and constrained with `minItems: 1`. `timeout` integer optional, milliseconds, constrained with `minimum: 1`. | Shared JSON envelope. `data.status` is `"passed"` or `"failed"` with `data.tasks`; infrastructure failures return coded `error` objects. | Natural start of a chain into `get_failure`, `run_fix`, and `get_history`. |
| `explain_pipeline` | Describe graph structure, dependencies, execution levels, critical path, and semantic metadata without running tasks. | `path` string optional, description quality: acceptable. | Shared JSON envelope. Success data is the `Sykli.Explain.pipeline/2` map; failures return coded `error` objects. | Chains well before `run_pipeline` and `suggest_tests`. Also useful after SDK edits. |
| `get_failure` | Return the latest or selected failure occurrence with error context. | `path` string optional, description quality: acceptable. `run_id` string optional, description quality: acceptable but format is unconstrained. | Shared JSON envelope. Success data is raw occurrence data. Missing data returns `mcp.no_occurrence`. | Chains from `run_pipeline` failure into `run_fix`; missing occurrence is machine-branchable. |
| `suggest_tests` | Suggest affected tasks for changed files using semantic coverage and dependency analysis. | `path` string optional, description quality: acceptable. `changed_files` array of strings optional, description quality: good. | Shared JSON envelope with `changed_files`, `affected`, `skipped`, and `run_tasks`; no-change output includes an empty `run_tasks` and a message. | Chains naturally into `run_pipeline` by passing `data.run_tasks` to `run_pipeline.tasks`. |
| `get_history` | Return recent run history and computed patterns. | `path` string optional, description quality: acceptable. `limit` integer optional, description quality: acceptable and constrained with `minimum: 1`. | Shared JSON envelope. Success data contains `runs` and `patterns`. | Useful after `run_pipeline` or `get_failure` to assess flakiness. Does not expose query filters, so agents must post-process. |
| `retry_task` | Re-run specific tasks by name. | `path` string optional, description quality: acceptable. `tasks` array of strings required, description quality: good and constrained with `minItems: 1`. | Shared JSON envelope. Success data contains retry results; missing tasks returns `mcp.missing_argument`. | Chains from `get_failure`, `suggest_tests`, or `explain_pipeline`. It partly duplicates `run_pipeline` with `tasks`, which may confuse agents. |
| `run_fix` | Analyze the last failure and return structured fix analysis. | `path` string optional, description quality: acceptable. `task` string optional, description quality: acceptable. | Shared JSON envelope. Success data is structured fix analysis; missing occurrence returns `mcp.no_occurrence`. | Natural terminal step after `get_failure`; its missing-data path is machine-branchable. |

## Tool Details

### `run_pipeline`

Parameters:

| Name | Type | Required | Description quality | Notes |
|------|------|----------|---------------------|-------|
| `path` | string | no | acceptable | Defaults to current directory. Could specify path containment expectations. |
| `tasks` | array<string> | no | acceptable | Filters by task name. Schema declares `minItems: 1`. |
| `timeout` | integer | no | acceptable | Milliseconds. Schema declares `minimum: 1`; no maximum. |

Return:

```json
{
  "status": "failed",
  "tasks": [
    {
      "name": "test",
      "status": "failed",
      "duration_ms": 42,
      "cached": false,
      "failure_semantics": {
        "class": "criteria_failure",
        "retryable": false,
        "source": "criteria",
        "reason": "success_criteria_failed",
        "message": "task 'test' failed success_criteria"
      },
      "agent_hints": {
        "retry_may_help": false,
        "inspect_target": false,
        "inspect_contract": true,
        "inspect_dependencies": false,
        "requires_human_decision": false,
        "unknown_failure_class": false
      },
      "success_criteria_results": [
        {
          "index": 0,
          "type": "exit_code",
          "status": "failed",
          "message": "expected exit code 0"
        }
      ]
    }
  ]
}
```

Each task may also include optional `error`, `failure_semantics`,
`agent_hints`, `contract_slice`, `success_criteria_results`, and
`evidence_results`; each is omitted when empty/nil. See
`docs/failure-semantics.md`, `docs/agent-readable-failure-output.md`, and
`docs/result-contract-slices.md` for the shapes.

### `explain_pipeline`

Parameters:

| Name | Type | Required | Description quality | Notes |
|------|------|----------|---------------------|-------|
| `path` | string | no | acceptable | Defaults to current directory. |

Return: shared JSON envelope with `Sykli.Explain.pipeline/2` map under `data`.

### `get_failure`

Parameters:

| Name | Type | Required | Description quality | Notes |
|------|------|----------|---------------------|-------|
| `path` | string | no | acceptable | Used only for cold `.sykli/occurrence.json` fallback. |
| `run_id` | string | no | acceptable | No pattern hint for valid run IDs. |

Return: shared JSON envelope with raw occurrence JSON map under `data`, or
`mcp.no_occurrence` under `error`.

The returned occurrence contains typed result-metadata fields in each
`data.tasks[]` record; see `docs/false-protocol-schema.md` for the on-disk
shape. Each `history.steps[].error` sub-object includes `failure_semantics`
alongside `code` and `what_failed`.

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
  "run_tasks": ["test"],
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
| `limit` | integer | no | acceptable | Defaults to 10. Schema declares `minimum: 1`; no upper bound. |

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
| `tasks` | array<string> | yes | good | Required. Schema declares `minItems: 1`; runtime also rejects empty arrays with `mcp.missing_argument`. |

Return: shared JSON envelope with structured retry result map under `data`, or
coded failure under `error`.

`retry_task` uses the same per-task return shape as `run_pipeline`, so the same
typed result-metadata fields apply.

### `run_fix`

Parameters:

| Name | Type | Required | Description quality | Notes |
|------|------|----------|---------------------|-------|
| `path` | string | no | acceptable | Defaults to current directory. |
| `task` | string | no | acceptable | Restricts analysis to a named failed task. |

Return: shared JSON envelope with `Sykli.Fix.analyze/2` map under `data`, or
coded failure under `error`.

`run_fix` returns the fix-analysis map produced by `Sykli.Fix.analyze/2`. It
does not surface `failure_semantics`, `agent_hints`, `contract_slice`,
`success_criteria_results`, or `evidence_results` as top-level fields. Agents
that want those typed facts should call `get_failure`.

## Gaps And Recommendations

> **Resolved by MCP agent-contract hardening:** items 1, 2, 5, 7, 8,
> and 9 below. `tools/call` now renders every result through the shared
> `Sykli.CLI.JsonResponse` envelope; failures are coded `%Sykli.Error{}`
> (`mcp.*` + `graph.invalid_contract`, see `docs/error-codes.md`) returned with
> `isError: true`; schemas carry `minimum`/`minItems`; `suggest_tests` returns a
> ready-to-call `run_tasks` list; tool descriptions use execution-graph language;
> and the module doc lists all seven tools. The remaining items (3, 4, 6, 10)
> are deferred.

1. ~~**Return envelopes are inconsistent with the CLI agent contract.**~~ Resolved — all tool results flow through `Sykli.CLI.JsonResponse`.

2. ~~**Error codes are missing from MCP failures.**~~ Resolved — failures are coded `%Sykli.Error{}` (`mcp.unknown_tool`, `mcp.no_occurrence`, `mcp.missing_argument`, `mcp.tool_crashed`, `graph.invalid_contract`).

3. **The tool list lacks `explain`, `query`, and richer history discovery parity.** `explain_pipeline` covers pipeline structure only; there is no direct MCP counterpart for `sykli query` grammar discovery or `sykli report`.

4. **Review primitives have no MCP surface yet.** Once review nodes ship, agents will need a read-only graph inspection tool and a controlled invocation tool for review primitive execution. Do not add it before the graph model lands.

5. ~~**Schemas should tighten loose integers and arrays.**~~ Resolved — `minimum` on `timeout`/`limit`, `minItems` on `tasks`.

6. **`retry_task` duplicates `run_pipeline` filtering.** Consider either documenting `retry_task` as a convenience wrapper or folding it into a more general `run_pipeline` schema with a clear `mode`.

7. ~~**`suggest_tests` should return a ready-to-call task list.**~~ Resolved — `suggest_tests` now returns a graph-ordered, deduped `run_tasks` array.

8. ~~**Tool descriptions still say "CI pipeline".**~~ Resolved — descriptions use execution-graph language.

9. ~~**Module documentation says five tools, but seven are exposed.**~~ Resolved.

10. **Token efficiency is uneven.** `get_failure` returns the full occurrence by default. Add a terse default with an explicit verbose flag or field selector so agents do not pay for large logs unless they ask.
