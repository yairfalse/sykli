# Codex prompt — Phase 2.5 findings remediation

Paste the block below into Codex's chat to start.

---

You are an engineering agent assigned to **fixing the 11 contract gaps** found by the Phase 2.5 oracle expansion (PR #129). The findings are documented in **`eval/oracle/findings-phase-2-5.md`**. The cases live in **`test/blackbox/dataset.json`**, currently marked `expected_failure: true` so they don't break CI.

This prompt closes the bug-tracking chain that the Phase 2.5 prompt assumed but didn't enforce: failing cases must drive bug fixes, and the `expected_failure: true` mark must be **removed** as each bug is fixed (not left as a permanent shrug). **Take no prisoners.** A finding is closed only when:

1. A GitHub issue exists tracking it.
2. A fix PR closes that issue.
3. The corresponding case in `dataset.json` no longer has `expected_failure: true`.
4. The case passes naturally — without `expected_failure` — under the fixed code.

## Read first, in order

1. **`CLAUDE.md`** at repo root — conventions, build/test commands, runtime isolation rule, NoWallClock rule, JSON envelope.
2. **`eval/oracle/findings-phase-2-5.md`** — the canonical list of 11 findings with severity, observed behavior, expected behavior, and requirement source.
3. **`test/blackbox/dataset.json`** — find every case with `"expected_failure": true` and its `"findings":` field. These are the cases you will be flipping.
4. **`test/blackbox/run.sh`** — see how `expected_failure` is interpreted by the runner. Removing the flag must result in the case being evaluated normally.
5. **The relevant requirement source per finding** — most cite CLAUDE.md sections, ADRs, or CHANGELOG entries. Read the source before writing the fix; some findings may turn out to indicate the *requirement* was wrong.

## The 11 findings — fix order is by severity, then ease

| # | Case | Severity | One-line gap | Requirement source |
|---|---|---|---|---|
| 1 | **GH-004** | **Critical** | A task command can copy `/etc/passwd` into the workspace | CLAUDE.md §Path containment; CHANGELOG 0.2.0 path-traversal fix |
| 2 | **ABN-015** | High | A task timeout is reported as `:failed` instead of `:errored` | CLAUDE.md §TaskResult Status Values |
| 3 | **DET-006** | High | NoWallClock Credo check does not reject `DateTime.utc_now` in a fixture violation file | CLAUDE.md §No wall-clock or global RNG |
| 4 | **SDK-001** | High | `tests/conformance/run.sh 01-basic` fails for non-Go SDK emitters | CLAUDE.md §SDKs; SDK READMEs |
| 5 | **SDK-002** | High | Capability conformance fails through the runner | CHANGELOG 0.5.0 capabilities; SDK READMEs |
| 6 | **SDK-003** | High | Gate conformance fails through the runner | CHANGELOG 0.5.0 gates; SDK READMEs |
| 7 | **SDK-004** | High | Task input conformance fails through the runner | README §Content-addressed caching; SDK READMEs |
| 8 | **SDK-006** | High | Empty-provides conformance fails through the runner | CHANGELOG 0.5.0 empty `provides` fix |
| 9 | **CACHE-006** | Medium | `sykli cache stats --json` prints help text instead of envelope JSON | CLAUDE.md §JSON output |
| 10 | **DET-003** | Medium | Two identical runs differ after stripping known-variable fields | CLAUDE.md §FALSE Protocol Occurrences |
| 11 | **SDK-005** | Medium | Duplicate dependency edge conformance fails through the runner | SDK READMEs |

## Critical context — the most likely places to misstep

- **GH-004 first, alone, fast.** The path-traversal finding is Critical security. It ships before any other fix. It also gets its own dedicated PR with a tight title (`fix(security): prevent host path read from task commands`) so the security signal is visible in `git log --oneline`. Do not bundle GH-004 into a multi-finding PR.
- **`expected_failure: true` is a temporary shrug, not a contract.** Every case currently flagged with it is a *known-broken* contract assertion that the runner is hiding. Removing the flag without fixing the bug breaks CI. Removing the flag *with* the fix is the deliverable. Removing it *and not flipping* the underlying behavior is wrong both ways.
- **Fix the bug, not the case.** If a case is poorly written and its current red is "noise" rather than a real gap, the right move is to **delete or rewrite the case**, not silently tighten its expectations. Document any such case in the PR body. The Phase 2.5 prompt's philosophy still applies: a case that doesn't catch a real gap is not a case worth keeping.
- **One issue per finding, regardless of how the fixes group.** Even if SDK-001..006 share a root cause and are fixed in one PR, file 6 issues and have the PR close all 6 (`Closes #N1, Closes #N2, …`). The issues are the audit trail; the PRs are the cure.
- **The runtime isolation rule applies.** No module outside `core/lib/sykli/runtime/` may name a runtime by class. If GH-004's fix involves the executor or target layer hardening path containment, the fix lives in `target/local.ex` or `services/`, not by adding a `Sykli.Runtime.Hardened` module.
- **NoWallClock applies to your fixes.** Don't introduce `DateTime.utc_now` while fixing DET-006; the check is exactly what's broken. Fix the *check*, not by routing around it.
- **Default `:test` runtime is `Sykli.Runtime.Fake`.** Tests don't need Docker. If a fix's test does need Docker, tag `@tag :docker` and run tier `mix test.docker` to verify; don't change the default.
- **The fix can change requirements.** If when fixing ABN-015 you discover the codebase's intent is actually that timeouts are command failures (not infrastructure), then the *requirement* was wrong, not the implementation. In that case: amend CLAUDE.md, delete the case, document the reasoning in the issue, and close the issue as `not a bug` rather than fixing nothing.

## Scope — what to do, in order

1. **Open 11 GitHub issues**, one per finding. Use this body template:
   ```
   ## Finding (Phase 2.5)

   - **Case:** <CASE-ID>
   - **Severity:** <Critical|High|Medium>
   - **Source:** <requirement document and section>
   - **Observed:** <one sentence from the findings doc>
   - **Expected:** <one sentence from the findings doc>

   ## How to reproduce

   <one shell snippet that triggers the failing case>

   ## Definition of done

   - The contract gap is fixed in `core/` (or the requirement is amended in `CLAUDE.md` if the case was wrong).
   - `dataset.json` case `<CASE-ID>` no longer carries `expected_failure: true` and passes naturally.
   - This issue is closed by a PR.
   ```
   Title: `[Phase 2.5] <CASE-ID>: <one-line gap>`. Label: `bug` + `phase-2-5`.

2. **Fix GH-004 first**, alone, in its own PR. Title: `fix(security): prevent host path read from task commands`. Closes the GH-004 issue. Removes `expected_failure: true` from GH-004 in `dataset.json`. The case must pass.

3. **Fix the SDK conformance findings (SDK-001..006) next**, likely in one or two PRs since they share infrastructure (the conformance runner + the per-SDK emitters). One PR if root cause is shared; up to three if the root causes split cleanly. Each PR closes the relevant issues by ID. `expected_failure: true` is removed from each fixed case.

4. **Fix the remaining Highs (ABN-015, DET-006)** — each in a dedicated PR.

5. **Fix the Mediums (CACHE-006, DET-003, SDK-005)** — can bundle into one PR titled `fix: close remaining Phase 2.5 medium-severity findings`.

6. After all 11 are closed, **delete the `expected_failure: true` predicate from `test/blackbox/run.sh`** if no other case in the dataset uses it. (`grep '"expected_failure"' test/blackbox/dataset.json` → no matches → delete the predicate.) The mechanism was a Phase 2.5 stopgap, not a permanent feature. Removing it is the final cleanup PR.

## Out of scope — DO NOT TOUCH

- ✗ Adding new oracle/black-box cases. The 11 findings are the bounded scope.
- ✗ ADRs. No new ADRs, no edits.
- ✗ The release tag, README, CLAUDE.md positioning. **Different Codex prompt.**
- ✗ The PR review feature. **Different Codex prompt.**
- ✗ Refactoring unrelated code. If you reach for an "while I'm here" cleanup, stop. Open it as a follow-up issue instead.
- ✗ Adding new dependencies.
- ✗ Changing the Phase 2.5 case shape beyond removing `expected_failure: true`. The cases were written to fail; they should now pass under the same shape.

## Conventions (from CLAUDE.md, non-negotiable)

- Behaviours over protocols. Structured `Sykli.Error` codes, never bare strings.
- `mix format && mix test && mix credo && mix escript.build` clean before commit.
- `test/blackbox/run.sh` clean before PR. Specifically: every fixed case must show `passed`, not `xfail`.
- One PR per logical fix (with the SDK-conformance bundle exception above). Each PR title includes the closed case ID(s).
- Commit messages cite the case ID and the requirement source.
- All commits end with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- Never push to main. Branch + PR.

## Acceptance criteria

After all PRs in this remediation pass merge:

- [ ] **11 GitHub issues** closed (or reframed-and-closed for any finding that turned out to be a wrong requirement).
- [ ] **`grep '"expected_failure": true' test/blackbox/dataset.json`** returns nothing. The mechanism is gone.
- [ ] **`grep "expected_failure" test/blackbox/run.sh`** returns nothing (the predicate is removed from the runner).
- [ ] **`test/blackbox/run.sh`** passes 100% naturally — no expected-fail accounting.
- [ ] **`tests/conformance/run.sh`** passes for all five SDKs across all listed cases.
- [ ] **`mix test`, `mix credo`, `mix escript.build`** clean.
- [ ] **`eval/oracle/findings-phase-2-5.md`** is annotated: each row gains a `Closed by #PR-N` column, and the doc's preamble is updated to "All findings closed as of <date>."
- [ ] **No regressions** in the 0.6.0 acceptance criteria from the release-and-docs prompt (run those checks again).

## Anti-patterns — do not do these

- ✗ Don't bundle GH-004 (Critical security) with anything else. Solo PR, fast review, fast merge.
- ✗ Don't remove `expected_failure: true` from a case without fixing the underlying bug. The mark is hiding broken behavior; removing it without fixing is a CI break.
- ✗ Don't fix the case without fixing the bug. "Make the test pass by changing the assertion" is the inverse failure mode.
- ✗ Don't open a single mega-PR closing all 11 issues. The audit trail (one PR closes one finding) is what makes this pass auditable. SDK conformance bundle is the single permitted exception.
- ✗ Don't introduce `expected_failure` for *new* known-broken behavior discovered during this work. Open an issue and either fix it in scope or defer to a follow-up — but don't extend the shrug.
- ✗ Don't touch the release artifacts, the README, CLAUDE.md, or ADRs.
- ✗ Don't auto-amend, don't `--no-verify`, don't bypass signing.

## Things to ask if you can

- For SDK conformance findings — should the fix preserve the existing emitted JSON shape (and update conformance fixtures) or change the shape to a new canonical form (and bump SDK semver)? **Default: preserve shape, update fixtures, no semver bump.** Conformance was meant to detect drift; the fix tightens behavior, not the schema.
- For DET-006 — if the NoWallClock check has a bug that lets `DateTime.utc_now` slip through under specific configurations, should the fix tighten the check across all envs or only the simulator-facing module set? **Default: tighten across all envs that currently run `mix credo`.**
- For ABN-015 — if the timeout/errored mapping requires changing `Sykli.Executor.run/3`'s status resolution, that's a semantically loaded change. Confirm before merging by re-running the existing executor test suite + a manual smoke against `sykli --timeout=1s` on a 10-second sleep task.

If you cannot ask, use the defaults.

---

**End of prompt.** This is the prompt that closes Phase 2.5. After every PR in this pass merges, the oracle suite has zero `expected_failure` cases, every finding has an issue and a fix PR in `git log`, and the next Codex prompt (PR review primitives) can build on a clean baseline.
