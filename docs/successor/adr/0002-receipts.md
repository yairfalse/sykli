# ADR-0002: Receipts are the sole evidence output

Status: accepted, 2026-08-04.

## Context

The reference implementation emitted FALSE Protocol occurrences: typed events
enriched with error analysis, reasoning, and history. The ecosystem deleted
that protocol (ahti M6, 2026-05) and converged on a doctrine: producers emit
structure; consumers own meaning. The surviving evidence patterns in the
family are teko's `GateReceipt` (valid only for the exact tree it witnessed,
complete output required) and toimija's content-addressed, consistency-token-
sealed gate receipts.

## Decision

Sykli emits exactly one evidence artifact: the **run receipt**, a JSON
document written to `.sykli/receipts/rcpt_<sha256-of-content>.json`.

A receipt binds:

- `contract_hash` — canonical hash of the executed contract (the lock-file
  hash when locked); the analog of teko's `gate_spec_digest`.
- `subject` — repository identity, tree OID at execution start, and a dirty
  marker when the working tree diverged from that OID.
- per-task records — task id, resolved command, runtime fingerprint,
  exit code, duration, output digests (stdout/stderr/declared outputs), and
  **complete captured output**. A truncated record poisons only itself, and
  is marked non-importable.
- outcome — one of `passed | failed | errored | cached | skipped | blocked`
  per task, plus the run-level rollup. `skipped`/`blocked` never roll up as
  success.
- for `cached`: a provenance ref to the receipt of the run that produced the
  artifact. A hit without resolvable provenance is executed as a miss.

Receipts carry **no** reasoning, no root-cause text, no suggested fixes, no
history narratives. Field names avoid the word "occurrence" entirely.

Authority is layered, never claimed: a sykli receipt asserts "this ran, here
is what happened". Toimija may seal it with a consistency token; teko alone
decides whether sealed receipts close work. Sykli never writes into either
tool's stores.

The optional ahti adapter (post-v0) wraps receipt facts as envelope + opaque
payload under the reserved `sykli.*` namespace, registered as definitions per
ahti's vocabulary rules. Appending is fire-and-forget and never gates a run.

## Consequences

- `--json` on every command is a view over the same receipt data — one shape
  to parse, no parallel envelope format.
- DSSE/SLSA attestations are dropped; the receipt's content-addressing and
  completeness rules subsume the integrity role locally. Registry-grade
  attestation, if ever needed, is a consumer built on receipts.
- Failure analysis for agents (the old enrichment) is now a *reader's* job:
  typed failure classes remain in the receipt (`class`, `retryable`,
  `source`), but interpretation lives in the tools that read it.
