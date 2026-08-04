# ADR-0005: The deletion record

Status: accepted, 2026-08-04. **Normative.**

## Context

The reference implementation grew capabilities the ecosystem later re-solved
with dedicated tools, or rejected outright. Per family doctrine ("when code
no longer fits the role, delete — don't extract"), the successor starts
without them. This record exists so deletions stay deleted: a capability
below does not return unless its stated re-entry condition is met, and a PR
reintroducing one must cite this ADR and the condition it satisfies.

## The record

| Capability (reference impl) | Where it went | Re-entry condition |
|---|---|---|
| Team Mode: work items, gate stores, coordinator server, daemon join/heartbeat, outboxes, team tokens | teko (work contracts, closure), toimija (gate authority, receipts) | Never. Sykli does not coordinate. |
| FALSE Protocol occurrences, enrichment (error/reasoning/history), three-tier occurrence store, PubSub event fabric | Deleted ecosystem-wide (ahti M6). Structure-only receipts replace it (ADR-0002); ahti append adapter carries facts later | Never in enriched form. Ahti adapter lands when the `sykli.*` schema pack exists on ahti's side. |
| v5 `actor` / `mandate`; agent-as-task-executor | The work layer: teko specs + `false-agent-protocol`; workers run via kisko under toimija | Never. Sykli executes commands, not actors. |
| `success_criteria`, `evidence_required`, `task_type` | Collapsed: success = exit code + declared outputs; evidence = receipts; typing = failure classes in the receipt | A family repo demonstrates a check the exit-code contract cannot express. |
| Review nodes / review primitives | A review is a task like any other; its verdict is its exit code and output | Same as above. |
| MCP server | Agents read `--json` (receipt-shaped); repository context is toimija's packet | An agent harness in family use that cannot shell out. |
| GUI / Workbench | None. Receipts are files; a viewer would be a separate tool | Someone builds the separate tool. |
| Kubernetes target | None | A family repo runs gates on k8s. Then: a runtime adapter behind the existing port, not a target subsystem. |
| S3 / tiered cache, circuit breakers | None (ADR-0004) | Receipts from family repos show cold-cache time hurting a real workflow a shared tier would fix. |
| DSSE attestations, SLSA provenance | Receipt content-addressing + completeness rules (ADR-0002) | An external registry requires signed attestation; built as a consumer of receipts. |
| Four of five SDKs (Go, TypeScript, Python; Elixir demoted to "second") | Schema remains canonical; emitters are additive (ADR-0003) | Elixir: vartio adopts sykli gates. Others: a named external user asks. |
| Webhook receiver, GitHub App, Checks API, SCM status | Triggers are external shims; a dumb Action invokes `sykli` | Never inside sykli. Shims live beside it. |
| Watch mode, matrix expansion, simulate, notifications/webhooks | None at v1 | A family repo asks, with the workflow written down first. |

## Consequences

- The successor's surface is: parse, validate, plan (delta), execute, cache,
  receipt. Everything in the table is somebody else's job or nobody's.
- This file is reviewed in every PR that grows the CLI surface. Growth
  without a cited re-entry condition is the definition of scope creep here.
- The reference implementation stays runnable for anything above until its
  users (if any) migrate or retire it.
