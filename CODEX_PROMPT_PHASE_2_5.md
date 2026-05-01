# Kickoff prompt for Codex — Phase 2.5: Requirement-Driven Oracle Expansion

Paste the block below into Codex's chat to start Phase 2.5.

---

You are an engineering agent assigned to **Phase 2.5** of the sykli quality program (working directory: `/Users/yair/projects/sykli`, default branch: `main`, remote: `git@github.com:false-systems/sykli.git`).

Phase 2.5 is **a focused expansion of the oracle and black-box suites against the project's requirements** — not against its code. The existing `test/blackbox/dataset.json` (92 cases) and `eval/oracle/` cases are dominated by happy-path smoke tests: "does it not crash on the obvious input." That's confirmation, not testing. **Phase 2.5 writes adversarial cases that try to break the contract.** If they fail, we found a gap and will fix sykli (or correct the test if the requirement was wrong). If they all pass, we wrote weak tests and need to harden them.

**This phase does not write per-code integration tests. It writes per-requirement contract assertions.** Read this distinction carefully — it is the entire point.

## Mission

Extend `test/blackbox/dataset.json` and add new cases under `eval/oracle/cases/` (create the directory if absent) with **adversarial, requirement-driven cases** that encode the contracts sykli has committed to in:

- The README (the local-first thesis, the user-visible promises)
- `CLAUDE.md` (the invariants — TaskResult statuses, runtime isolation, NoWallClock, JSON envelope shape)
- All ADRs in `docs/adr/` (what the architecture commits to, especially ADR-020 visual rules and ADR-021 GitHub-native security requirements)
- The `CHANGELOG.md` entries through 0.6.0 (every "Security" and "Reliability" entry is a contract)
- The five SDKs' public surfaces (cross-SDK behavioral parity)

Every case is a contract assertion — what the system *must* do — not a test of *how* the code works. **The tester is blind to sykli's internals.** It runs the binary, observes via stdout / stderr / exit code / files written under `.sykli/` / occurrences emitted / network calls (mockable). It never imports a sykli module, never reads sykli source code, never patches internal behavior.

## The philosophy — read this twice

**A passing case is suspicious. A failing case is information.**

You are not writing tests to confirm sykli works. You are writing tests to find places where sykli *says* it does X but doesn't actually do X. If you write 30 cases and they all pass on day one, you wrote 30 weak cases. Sharpen them until at least some of them find real gaps.

When a case passes:
- Validate why. Did sykli actually fulfill the requirement, or did the case fail to provoke the failure mode? Try to break the case by injecting a temporary bug into sykli (e.g., comment out the signature verification) — if the case still passes, it's not testing what you think it's testing.
- Acceptance: a case is "real" if it can detect at least one concrete bug you could plausibly introduce. Document that bug in a `# Validated by` comment in the case spec. If you can't think of one, the case is too weak — discard or sharpen.

When a case fails:
- That's the win. File it as a sykli bug (or, if you find the requirement was wrong, reframe the test). Phase 2.5's deliverable is **the failing cases**, not green checkmarks.

**Don't care about happy paths.** The existing 92 blackbox cases cover them. Phase 2.5's value is in the cases that probe the edges of the contract.

## Read first, in order

1. **`CLAUDE.md`** at repo root — always-on operating manual. The invariants and conventions you must respect when writing fixtures. Pay special attention to: TaskResult statuses (`:passed | :failed | :errored | :cached | :skipped | :blocked`), JSON envelope shape, runtime isolation rule, NoWallClock rule.

2. **The full ADR set** in `docs/adr/`. Skim 001–019; read 020 and 021 in full. Every ADR with `Status: Accepted` is a frozen contract — those are the highest-priority sources of requirements. Proposed ADRs are softer commitments but still binding for shipped behavior.

3. **`CHANGELOG.md`** entries `[0.5.0]` and forward. Every line under **Security**, **Reliability**, and **Migration notes** is a contract sykli has publicly committed to. SEC-001..007, REL-002..008 are explicitly named — each is a testable assertion.

4. **The existing `test/blackbox/dataset.json`** (92 cases) and **`test/blackbox/run.sh`**. Read the runner to understand the supported case shape (`fixture`, `command`, `expect_exit`, `expect_stdout`, `expect_stdout_contains`, `expect_json`, `expect_json_contains`, `shell` flag). You will extend this format (add new `expect_*` predicates if needed) but stay backward-compatible.

5. **`test/blackbox/fixtures/`** — read 5–10 fixtures to understand the SDK file shape. Most are single-line `IO.puts(~s({"version":"1","tasks":[...]}))` patterns. Your fixtures use the same idiom; do **not** reach for elaborate Mix projects.

6. **The README.md** — the user-visible promises. "Local-first CI for the next generation of software developers" is now a testable claim. So is "AI agents read your runs natively." So is "Determinism by default."

7. **The five SDK READMEs** at `sdk/*/README.md` — cross-SDK behavioral parity is a contract. If the Go SDK accepts `provides("name", "value")`, every other SDK must too, with identical JSON output for equivalent inputs.

## Critical context — the most likely places to misstep

- **The tester is blind.** Cases use only: the `sykli` binary, fixture pipeline files in `test/blackbox/fixtures/`, env vars, the working directory, exit codes, stdout/stderr, files in `.sykli/`, the JSON envelope output, occurrences in `.sykli/occurrence.json` or `.sykli/occurrences_json/`. Cases NEVER read `core/lib/sykli/*.ex`, NEVER import sykli modules, NEVER patch internal behavior. If you find yourself wanting to inspect an internal data structure, you are writing the wrong kind of test — translate the requirement into a user-observable consequence and assert on that.

- **Don't restate happy-path cases in adversarial form.** The existing dataset has 92 cases. Read them all before adding. Duplicating "validate accepts a valid pipeline" with a different fixture is not a Phase 2.5 case. A Phase 2.5 case looks like: *"validate accepts a pipeline whose JSON contains a UTF-8 BOM and 4096 nested matrix dimensions, OR rejects it with a structured error code — never crashes, never outputs an empty envelope"*.

- **Requirements live in prose, not code.** Source the contracts from CLAUDE.md, ADRs, CHANGELOG entries, and README claims. Every Phase 2.5 case carries a `# Source` comment naming the requirement document and section ("Source: ADR-021 §Security, paragraph 3"). If you can't cite a source, you're writing a guess, not a contract test.

- **Cache fingerprint isolation (0.6.0 BREAKING) is a goldmine.** "Two projects in different directories with the same task graph must NOT share cache." Adversarial: create the same `sykli.exs` in two temp dirs, run each, observe cache state (`.sykli/cache/` paths or stat keys) — assert no overlap.

- **Status-distinction requirements are goldmines too.** `:failed` (command non-zero) vs `:errored` (infrastructure: timeout, OIDC, missing secret, process crash) is a contract per CLAUDE.md. Cases that trigger each kind and assert on the resolved status in `.sykli/occurrence.json`. If both conditions resolve to the same status atom, that's a bug.

- **NoWallClock invariant is testable.** When sykli runs with `SYKLI_CLOCK=fixed:2026-04-29T00:00:00Z` (or whatever fixture time mechanism is exposed — read `Sykli.GitHub.Clock.Fake` and the simulator transport docs), running the same pipeline twice should produce occurrence payloads that differ ONLY in run_id and absolute timestamps within the configured deterministic regions. Adversarial: hash the entire occurrence after stripping known-variable fields; assert byte-for-byte equality across runs.

- **The webhook signature contract is testable end-to-end.** Send a valid-signed webhook → expect 202. Send a wrong-signed webhook → expect 401 AND verify the response time is constant (HMAC compare must not short-circuit) AND verify the body bytes do not appear in stderr. The receiver runs as a process; spin it up via the `sykli mcp`-style stdio model or as a real HTTP listener on localhost.

- **Cache hit means the command did NOT run.** This is the strongest cache contract. Use a side-effect-bearing command (`echo "$(date +%s)" > /tmp/sykli-cachetest-<run_id>`); run twice; assert the file's content from the second run matches the first (i.e., the second run did not execute the command). If the contents differ, the cache silently re-executed — that's a bug.

- **Cross-SDK behavioral parity** is a five-way contract. The same logical pipeline written in `sykli.go`, `sykli.rs`, `sykli.ts`, `sykli.exs`, `sykli.py` must emit byte-identical (or normalized-equivalent) JSON via `--emit`. Adversarial: define one canonical pipeline in five fixtures, run `sdk-emit-equivalence` cases that diff the JSON outputs.

- **Don't be lulled by exit code 0.** A passing exit code with corrupted `.sykli/occurrence.json` or a missing attestation is still a contract violation. Assertions must check more than `expect_exit: 0`.

- **NoWallClock applies to your fixtures and runner too.** If a case's expected output includes a timestamp, the runner is comparing wall-clock dependent strings — it will be flaky. Use placeholder matchers (`"<timestamp>"`) or strip variable fields before comparing.

## Phase 2.5 scope — what to add

Aim for **40–60 new cases**, distributed across the existing categories plus two new ones. The numbers below are floors, not ceilings — if a category yields more failing cases, ship them all.

Case ID format: `<CAT>-<NNN>` where `NNN` continues the existing numbering (so a new POS case is `POS-024`, etc.). **Numeric IDs are stable. A deleted case leaves a numeric gap; never reuse an ID.**

A. **Cache contract (12+ cases, new category prefix `CACHE-`).**
- Workdir-isolation: identical task in two dirs → no cache reuse.
- OIDC-credentialed runs: cache key includes the resolved credential hash (per SEC-007).
- Cache hit means command does NOT run (side-effect verification).
- Cache key stability: two runs with identical inputs produce identical cache keys.
- Cache key sensitivity: changing one byte in `Inputs("**/*.go")` changes the key.

B. **Status-distinction contract (8+ cases, expand `NEG-` and `ABN-`).**
- Command non-zero exit → `:failed` (not `:errored`).
- Reference missing secret → `:errored` (not `:failed`).
- Hard timeout (kill -9 on a long-running task) → `:errored`.
- OIDC token request failure → `:errored`.
- Conditional skip → `:skipped`, never `:cached`, never `:passed`.
- Dependency failed → dependent task is `:blocked`, never executed (verify side-effect).

C. **JSON envelope contract (6+ cases, new prefix `JSON-`).**
- Every `--json`-supporting command emits `{ok, version, data, error}` shape.
- The `error_with_data` variant: `validate` on malformed pipeline → `{ok: false, data: <errors>, error: null}`.
- `version` field is exactly `"1"` (string, not number) for 0.6.x.
- Stdout for `--json` contains exactly one JSON object, terminated by newline, with no ANSI escapes.
- `error.code` is a snake_case namespaced string (e.g., `github.app.unauthorized`); never bare prose.

D. **Determinism / NoWallClock contract (6+ cases, new prefix `DET-`).**
- Two runs of the same pipeline with the same fixture clock produce byte-identical occurrence payloads modulo declared variable fields.
- A run with the simulator transport (`SYKLI_TRANSPORT=sim`) is replayable from a recorded seed.
- The custom Credo check exists and rejects `DateTime.utc_now` in fixture violation files (run `mix credo` against a test fixture).

E. **Cross-SDK parity (10+ cases, new prefix `SDK-`).**
- Five fixtures (one per SDK) with the canonical "two dependent tasks" pipeline → byte-identical normalized JSON output via `--emit`.
- Five fixtures with capabilities (`provides`/`needs`) → byte-identical capability resolution.
- Five fixtures with gates → byte-identical gate JSON shape.
- One fixture per SDK with a deliberate violation (cycle, self-dep, duplicate name) → all five SDKs reject pre-emit with comparable error messages.

F. **Visual reset contract (6+ cases, new prefix `UI-`).**
- Failing run output ends with the literal line `Run  sykli fix  for AI-readable analysis.` (per ADR-020).
- The banned strings (`"Level"`, `"1L"`, `"(first run)"`, `"Target: local (docker:"`, `"All tasks completed"`) appear in zero passing-run outputs.
- Cache-hit output uses `○` (U+25CB), passed uses `●` (U+25CF), failed uses `✕` (U+2715), blocked uses `─` (U+2500). Run a fixture covering each; assert presence.
- TTY-detection: piping `sykli` output to a file produces zero ANSI escape codes (no `\e[`).
- Single summary per run: passing 5-task fixture's output contains exactly one occurrence of `passed` as a summary line (not as part of task names).

G. **GitHub-native security contract (4+ cases, new prefix `GH-`, integration-tagged).**
- Webhook with wrong signature → 401 within 50ms, body bytes never appear in stderr.
- Webhook with valid signature but replayed `X-GitHub-Delivery` ID → rejected (200 or 4xx, but not 202; receiver state unchanged).
- App credentials missing → receiver still 202s the webhook (Phase 1 degraded behavior preserved); `ci.github.webhook.received` still emits.
- Source clone path containment: a fixture pipeline whose commands try `cat ../../etc/passwd` from the cloned dir fails safely (Phase 2 only — skip if Phase 2 hasn't merged).

## Out of scope — DO NOT TOUCH

- ✗ Any module under `core/lib/sykli/`. The tester is blind. Modifying source code to make a test pass is the wrong direction; if a case fails, file the bug, do not patch.
- ✗ The five SDKs themselves. Tests use the SDKs as opaque emitters.
- ✗ The visual reset modules (`Sykli.CLI.Renderer/Theme/Live/FixRenderer`). Their *output* is a contract; their internals are off-limits.
- ✗ Adding new dependencies to `core/`. Test cases are pure data + shell; the runner stays as-is.
- ✗ Rewriting existing happy-path cases. Add new ones; touch existing ones only if they are factually wrong.
- ✗ `eval/harness/` (the AI-agent eval loop). Out of scope for this phase.
- ✗ ADRs themselves. No edits.

## Conventions (from CLAUDE.md, non-negotiable)

- Fixtures are single-line JSON emitters where possible (`IO.puts(~s({"version":"1","tasks":[...]}))`); avoid heredocs because they embed literal newlines that break JSON.
- Every case carries a `# Source` field naming the requirement document and section.
- Every case has a numeric ID, never reused; deleted cases leave a gap.
- The runner stays at `test/blackbox/run.sh`; if you need a new predicate (`expect_no_ansi`, `expect_no_stderr_contains`, `expect_runtime_under_ms`), add it to the runner and document the format in a comment at the top of the dataset.
- For oracle cases under `eval/oracle/cases/`, follow the existing YAML format if cases already exist; if `cases/` is empty, define a minimal YAML schema and document it in `eval/oracle/README.md`.
- Adversarial fixtures may contain things that look broken (BOMs, deeply nested arrays, near-zero-byte files, paths with traversal sequences). They are intentional. Comment them.

## Implementation sequence

1. Branch from `main`: `git checkout main && git pull && git checkout -b feat/oracle-phase-2-5`.
2. Read the listed sources (CLAUDE.md, ADRs, CHANGELOG sections). Build a working list of contracts. Pick the 40–60 most adversarial.
3. For each candidate case: write the fixture (if needed), write the case spec, **run it**, observe pass/fail.
4. For each passing case: validate by injecting a temporary bug into the relevant sykli module, re-run, confirm the case fails. Revert the bug. If the case still passed under the bug, the case is too weak — sharpen or discard.
5. For each failing case: capture the failure mode in the case's `# Findings` comment; do **not** patch sykli. The PR ships failing cases; sykli fixes happen in follow-up PRs.
6. Update `test/blackbox/run.sh` with any new predicates; document them.
7. Run the full suite: `test/blackbox/run.sh`. Confirm: existing 92 cases still pass; some Phase 2.5 cases fail (expected); zero unexpected failures elsewhere.
8. Run `cd core && mix format && mix test && mix credo && mix escript.build` — Phase 2.5 must not regress unit tests or the build.
9. Commit in logical chunks:
   - `test(blackbox): add cache contract cases (CACHE-001..NNN)`
   - `test(blackbox): add status-distinction cases (NEG/ABN expansions)`
   - `test(blackbox): add JSON envelope contract cases (JSON-001..NNN)`
   - `test(blackbox): add determinism cases (DET-001..NNN)`
   - `test(blackbox): add cross-SDK parity cases (SDK-001..NNN)`
   - `test(blackbox): add visual reset contract cases (UI-001..NNN)`
   - `test(blackbox): add GitHub webhook security cases (GH-001..NNN)`
   - `test(blackbox): extend runner with new expect_* predicates`
   - `docs: document oracle case schema and Phase 2.5 findings`
10. Push and open PR titled **`test(blackbox): Phase 2.5 — Requirement-Driven Oracle Expansion`**. Body: 1-line summary + bulleted scope + a table listing every new case ID that **fails**, with the requirement source and the observed gap. The failing cases are the deliverable.

## Acceptance criteria

- [ ] 40+ new black-box / oracle cases added, distributed across the categories above.
- [ ] **At least 5 of the new cases fail.** A PR with zero failures is suspicious; either the cases are too weak or the validation step (injecting bugs) was skipped. State the failure count in the PR body.
- [ ] Every new case carries a `# Source` citation naming the requirement document.
- [ ] Every passing case has a `# Validated by` line documenting at least one bug that *would* make it fail (i.e., the case has been validated against an injected fault).
- [ ] `test/blackbox/run.sh` continues to run; output format is unchanged for existing cases.
- [ ] `cd core && mix test` still passes (no regressions to unit tests).
- [ ] Failing cases are documented in `eval/oracle/findings-phase-2-5.md` with: case ID, requirement source, observed behavior, expected behavior, severity. This document is the deliverable for follow-up bug PRs.
- [ ] No file under `core/lib/sykli/`, `sdk/`, or `docs/adr/` is modified by this PR.

## Anti-patterns — do not do these

- ✗ Don't write tests that pass on the first try without validation. A passing test is suspicious. Validate by injecting a bug.
- ✗ Don't import or read sykli source modules. The tester is blind. If you need to know what `Sykli.Cache.fingerprint/1` does, you're testing the wrong layer.
- ✗ Don't fix sykli bugs in this PR. Phase 2.5 ships the *failing cases*. Bug fixes are follow-up PRs that reference the failing case IDs.
- ✗ Don't restate happy-path cases as adversarial. "validate works on a valid pipeline" is not a Phase 2.5 case, no matter how exotic the fixture.
- ✗ Don't use timestamps or wall-clock-dependent values in expected outputs without a placeholder matcher. NoWallClock applies to your fixtures.
- ✗ Don't mock sykli internals. If a contract isn't observable from outside, write a different case that asserts an observable consequence.
- ✗ Don't aggregate multiple requirements into one case. One case = one contract assertion. A case that asserts both "JSON envelope shape" and "exit code is 0" is two cases.
- ✗ Don't auto-amend commits, don't `--no-verify`, don't bypass signing.

## Things to ask if you can

- Should the new prefixes (`CACHE-`, `JSON-`, `DET-`, `SDK-`, `UI-`, `GH-`) be added to the dataset's `categories` block at the top, or kept implicit? Default: **add them** to `categories` for discoverability.
- For the cross-SDK parity cases (E), the existing `tests/conformance/` infrastructure may already cover some of this. Default: **prefer extending `tests/conformance/`** if it can carry the assertion; only add to `test/blackbox/` if conformance can't.
- Should failing-case findings be in a single `findings-phase-2-5.md` doc or one issue per failure? Default: **single doc in this PR + open one GitHub issue per high-severity finding** after merge.

If you cannot ask, use the defaults.

---

**End of Phase 2.5 prompt.** This phase delivers failing cases. The follow-up phases are sykli bug fixes for each finding, prioritized by severity. Do not mix the two — Phase 2.5 is the diagnosis; the cure ships separately.
