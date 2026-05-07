# Phase 2.5 Findings

These are requirement-level gaps found by the new adversarial black-box and
oracle cases. Fixes are intentionally out of scope for this PR.

## Status note after PR #173-#177

This file is historical audit input. The table below is not deleted because it
records what the oracle observed at the time, but several findings are stale
after the contract cleanup PRs.

| Case(s) | Status | Evidence / next action |
| --- | --- | --- |
| SDK-001 through SDK-006 | Stale / fixed by recent PRs | Cross-SDK conformance now covers all five SDKs and includes gates, capabilities, task inputs, duplicate dependencies, and empty capability values. Keep conformance green instead of editing the original finding rows. |
| CACHE-006 | Still open / needs focused fix | `core/lib/sykli/cli.ex` still has a dedicated `cache stats` branch and no confirmed JSON envelope coverage in this audit pass. |
| ABN-015 | Still open / needs focused fix | Timeout status semantics are not changed by PR #173-#177. |
| DET-003 | Still open / needs re-verification | Occurrence determinism was not re-audited in this docs pass. |
| DET-006 | Still open / needs PR E | NoWallClock scope and target-local determinism are assigned to the security/determinism hardening PR. |
| GH-004 | Still open / critical | Path traversal / host filesystem containment requires a scoped security fix, not a docs change. |

| Case | Requirement Source | Observed Behavior | Expected Behavior | Severity |
| --- | --- | --- | --- | --- |
| CACHE-006 | CLAUDE.md §JSON output | `sykli cache stats --json` prints cache command help; the runner finds no JSON object. | JSON-supporting commands emit `{ok, version, data, error}` with no ANSI. | Medium |
| ABN-015 | CLAUDE.md §TaskResult Status Values | A task timeout is reported as `failed`. | Infrastructure timeouts are `errored`, distinct from command failures. | High |
| DET-003 | CLAUDE.md §FALSE Protocol Occurrences | Two identical runs differ after stripping known variable fields. | Occurrence payloads are replayable modulo declared variable fields. | Medium |
| DET-006 | CLAUDE.md §No wall-clock or global RNG | A temporary `DateTime.utc_now` use under `core/lib/sykli` is not rejected by the configured credo run. | NoWallClock rejects direct wall-clock calls in simulator-facing code. | High |
| SDK-001 | CLAUDE.md §SDKs; SDK READMEs | `tests/conformance/run.sh 01-basic` fails for non-Go SDK emitters. | Equivalent basic pipelines emit normalized-equivalent JSON in all five SDKs. | High |
| SDK-002 | CHANGELOG 0.5.0 capabilities; SDK READMEs | Capability conformance fails through the runner. | `provides`/`needs` behavior is equivalent across all SDKs. | High |
| SDK-003 | CHANGELOG 0.5.0 gates; SDK READMEs | Gate conformance fails through the runner. | Gate JSON shape is equivalent across all SDKs. | High |
| SDK-004 | README.md §Content-addressed caching; SDK READMEs | Task input conformance fails through the runner. | Input declarations serialize equivalently across all SDKs. | High |
| SDK-005 | SDK READMEs | Duplicate dependency edge conformance fails through the runner. | Edge-case dependency serialization is equivalent across all SDKs. | Medium |
| SDK-006 | CHANGELOG 0.5.0 empty `provides` fix | Empty-provides conformance fails through the runner. | Empty string capability values are preserved across SDKs. | High |
| GH-004 | CLAUDE.md §Path containment; CHANGELOG 0.2.0 path traversal fix | A task command can copy `/etc/passwd` into the workspace. | Task execution prevents reading host paths outside the workspace/container boundary. | Critical |
