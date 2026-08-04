# ADR-0003: Contract schema reset; one SDK

Status: accepted, 2026-08-04.

## Context

The reference pipeline schema reached v5: resources, task types, success
criteria, evidence requirements, actors, mandates, review nodes — each
mirrored across five SDKs, a JSON schema, two engine paths, and conformance
fixtures. The 5× fan-out taxed every contract change, and the v5 agent
vocabulary now has a rightful home elsewhere (actors/mandates belong to the
work layer — teko and `false-agent-protocol`; evidence became receipts,
ADR-0002).

What proved right and is kept: **code emits JSON; the schema is the canonical
contract; the engine validates strictly.** The `--emit` seam made every SDK
a pure emitter and made conformance testable.

## Decision

New schema, `sykli-contract.v1`, strict (`additionalProperties: false`), no
compatibility with pipeline v1–v5. A task declares:

- `name`, `run`, `workdir`, `env`
- `after` — dependencies
- `inputs` / `outputs` — the cache and delta contract
- `runtime` — optional runtime selector (shell default; container later)

Nothing else at v1. No gates, no review nodes, no actors, no mandates, no
task types, no success criteria (success = exit code plus declared outputs
existing), no matrix (re-enters only with a real family use case).

**One SDK: Rust** (`sykli.rs`, the pattern already present in toimija's and
ahti's repos). The schema remains the contract, so additional emitters are
additive: Elixir second (for vartio) when it has a user, others on external
demand. Conformance harness carries over conceptually — every emitter must
produce semantically identical JSON for shared cases.

Contract identity: canonical hash over key-sorted re-encoded JSON (carried
from the reference `ContractHash`), and `sykli.lock` pins it. The lock hash
is the receipt's `contract_hash` (ADR-0002) and the natural
`gate_spec_digest` for toimija's gate catalog.

## Consequences

- Contract changes cost one emitter + one schema + one validator — the
  iteration tax drops ~5×, on the layer that most needs freedom to move.
- Existing v1–v5 pipelines do not run on the successor. The reference
  implementation remains available for them; there is no migration shim.
- Versioning discipline carries over: unknown keys are rejected, version
  bumps are explicit, and the schema gates fields by version from day one.
