# ADR-0004: Local content-addressed cache; tiering deferred

Status: accepted, 2026-08-04.

## Context

The reference implementation's cache proved the model: SHA256 keys over task
definition + input file hashes, cache hits as first-class task outcomes, and
delta selection (affected tasks from changed files) built on the same
`inputs` declarations. It also grew an S3 tier with circuit breakers —
network machinery with no internal user.

The successor's first users run gates at pre-commit, session exit, and CI.
The win they need is *warm local caches making gates take seconds*; a cold
Actions runner re-executing is acceptable and honest.

## Decision

- Cache key: SHA256 over (canonical task definition ⊕ content hashes of
  declared `inputs` ⊕ runtime fingerprint). Undeclared inputs are the user's
  contract violation — no filesystem tracing at v1.
- Store: local content-addressed directory (`.sykli/cache` or XDG,
  repo-scoped by default), storing declared `outputs` plus the producing
  receipt ref. Eviction by size/age, receipt refs never dangle silently — an
  unresolvable provenance ref demotes the hit to a miss (ADR-0002).
- Delta: changed-files → affected-tasks selection via the `inputs`
  declarations, carried from the reference implementation. Delta is a *plan*
  operation, cache is an *execution* operation; they share the input
  contract, not code paths.
- **No network tiers at v1.** The storage layer sits behind a small trait
  (the escape hatch), but no S3, no remote cache protocol, no daemons.
  Re-entry condition (recorded in ADR-0005): receipts from family repos
  demonstrate cold-cache time actually hurting a real workflow that a shared
  tier would fix.

## Consequences

- The v1 cache is fully inspectable with `ls` and `jq` — debuggability over
  cleverness.
- CI runners are cold by default. That is a feature at first: it keeps the
  cache-correctness bar honest before any cache is ever shared.
- Cross-machine reproducibility claims stay modest: the runtime fingerprint
  keys hits to compatible environments rather than pretending hermeticity —
  the same honesty toimija applies with `unenforced_deny_requested`.
