# Sykli — Founding Document (successor)

Status: draft, 2026-08-04. This document founds the next sykli — a clean-break
rewrite. The current repository becomes the reference implementation; its test
suite is the executable specification. Decisions here are recorded as ADRs in
`adr/`.

## Identity

**Sykli executes declared graphs and proves what ran.**

One sentence, same as its siblings: Ahti stores structure. Teko owns work.
Toimija verifies repositories. Kisko runs workers. Sykli runs graphs.

## Invariant

**A receipt claims exactly what ran — never what it meant.**

Corollaries, in family style:

- A cached result must carry provenance to the run that produced it; a cache
  hit without provenance is a miss.
- `skipped` and `blocked` never count toward `passed`. Failure never
  strengthens.
- Truncated output makes a receipt non-importable. Complete evidence or no
  claim.
- Sykli's receipts are claims *by sykli*. Authority over what a receipt closes
  belongs upstream (toimija seals, teko decides).

## Thesis: CI is four jobs, and sykli does one

Every CI system conflates four jobs:

| Job | Who does it now | Who does it here |
|---|---|---|
| Trigger | webhooks, cron, YAML `on:` | anything: git hook, session exit, a dumb Actions shim, `cron` |
| Environment | hosted runners | the Runtime port (shell, container) |
| **Execution** | the CI service | **sykli** — parallel DAG, content-addressed cache, delta |
| Reporting | status APIs, badges, dashboards | receipts on disk; consumers decide what they mean |

Sykli owns execution only, and owns it completely. "CI" degrades to: the same
graph, run anywhere, receipts as the only output that matters. A GitHub Action
is a machine that runs `sykli` with a cold cache — not a place where truth
lives.

## Composition

```
teko ──work.v1──▶ toimija ──gate──▶ sykli ──receipt──▶ toimija seals ──▶ teko closes
                                      │
                                      └──(later)──▶ ahti append, sykli.* namespace
```

- **toimija → sykli**: toimija materializes a snapshot and runs
  `sykli gate <id> --json`. Sykli returns a receipt: contract hash, tree OID,
  per-task output digests, exit codes, durations, complete output. Toimija
  seals it with its consistency token. Sykli does not know toimija exists;
  the dependency points at sykli's CLI contract, never back.
- **teko**: never talks to sykli. It imports sealed receipts through toimija
  (`work.observe_gates`) and alone decides closure.
- **ahti**: an optional append adapter emitting envelope + opaque payload under
  the reserved `sykli.*` namespace (ahti schema pack, currently unbuilt).
  Default is offline: receipts are files.
- **agents**: read `--json`. Repository context comes from toimija packets,
  not from sykli.

The keystone carried over from the reference implementation: the canonical
**contract hash** and the **lock file**. A locked contract is a pinned gate
definition — the same role `gate_spec_digest` plays in teko's receipts.

## Not

- **Not a work tracker.** Specs, obligations, closure — teko.
- **Not a verification authority.** Trusted gate catalogs, receipt sealing,
  repository truth — toimija.
- **Not an agent runner.** Model execution and worker results — kisko, via
  worker.v1. Sykli executes commands; who commanded them is upstream's
  problem.
- **Not a datastore.** Ahti stores; sykli emits.
- **Not a server.** No daemons, no network listeners, no coordinator. A
  future coordination need is met by a separate receipt-speaking tool.
- **Not an interpreter.** No reasoning fields, no enrichment, no causality,
  no "AI memory". Structure out; meaning is the consumer's job.

## What carries over, what does not

Carried from the reference implementation: graph parse/validate, executor
scheduling, content-addressed caching, delta selection, the Runtime port,
contract hashing and locking, typed failure classes, the CLI visual language
(glyphs, one accent, one summary).

Everything else is recorded — with its destination and its re-entry
condition — in [ADR-0005](adr/0005-deletions.md). That document is normative:
a deleted capability does not return without meeting its stated condition.

## First users

Its own family. The concrete v1 pitch to ahti, toimija, and teko: replace
`cargo xtask gate` with a cached, delta-aware graph that runs identically at
pre-commit, session exit, and in Actions — and whose receipts are importable
as closure evidence. If sykli cannot win its own siblings back, it has no
business courting strangers.

## v0 slice

1. Parse a contract emitted by `sykli.rs` (`--emit`, schema
   `sykli-contract.v1`).
2. Validate: DAG, cycles, unknown keys rejected.
3. Execute: parallel by dependency level, shell runtime, streamed output.
4. Cache: content-addressed, local, provenance-carrying hits.
5. Delta: affected-task selection from changed files.
6. Receipt: one JSON file per run, content-addressed, complete output.

Container runtime, toimija gate mode, and the ahti adapter come after the
family's own repos run v0 daily.

## Decisions

| ADR | Decision |
|---|---|
| [0001](adr/0001-rust.md) | Rust; single crate + xtask; family guardrails |
| [0002](adr/0002-receipts.md) | Receipts as the sole evidence output |
| [0003](adr/0003-contract-schema-reset.md) | Contract schema reset to v1; one SDK |
| [0004](adr/0004-cache-model.md) | Local content-addressed cache; tiering deferred |
| [0005](adr/0005-deletions.md) | The deletion record (normative) |
