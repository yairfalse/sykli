# Codex prompt — Release v0.6.0 properly + close all docs/positioning gaps

Paste the block below into Codex's chat to start.

---

You are an engineering agent assigned to **a release-and-docs cleanup pass** in the `sykli` repository (working directory: `/Users/yair/projects/sykli`, default branch: `main`, remote: `git@github.com:false-systems/sykli.git`).

This is not a feature pass. It is a **finishing pass** on the v0.6.0 release that landed in PR #127 + adjacent docs PRs. The repo is currently in an inconsistent state: code claims `0.6.0`, the last actual release is `v0.5.2`, the README and CLAUDE.md are stale on the new positioning, ADR-022 is marked `Proposed` despite being applied. Your job is to make the release, the documentation, and the canonical positioning all agree. **Take no prisoners. No half-fixes.**

You produce **one PR** (or two, if you split release tagging from doc fixes — see "Splitting" below). Either way, by the time this work merges, every problem listed below is closed.

## Read first, in order

1. **`CLAUDE.md`** at repo root — always-on operating manual. Conventions, build/test commands, the runtime isolation + NoWallClock + JSON envelope rules.
2. **`docs/adr/022-execution-graph-compiler-reframing.md`** — the canonical positioning. Lead sentence: *"sykli is a compiler for programmable execution graphs."* CI is one use case.
3. **`docs/adr/020-positioning-and-visual-direction.md`** — superseded for *positioning*; the *visual direction* section remains canonical. Read both clauses in ADR-022's "What does not change" section.
4. **`docs/releases/v0.6.0.md`** — the release notes file written for this release. Use it as the GitHub Release body.
5. **`CHANGELOG.md`** entry `[0.6.0] - 2026-04-29` — the canonical change list for this release.
6. **`README.md`** and **`install.sh`** — installer fetches `releases/latest`. There is currently no `v0.6.0` release, so the installer ships v0.5.2.

## The list (every item below must be closed)

### Release tagging (Critical — without this, the rest is moot)

- [ ] Tag `v0.6.0` at the current `main` HEAD.
- [ ] Push the tag to origin.
- [ ] Verify the tag triggers `.github/workflows/release.yml`. If the release workflow does **not** auto-fire on tag, run the equivalent steps locally:
  - Build the escript (`cd core && mix escript.build`) plus the Burrito-packaged binaries the existing release workflow produces.
  - Create a GitHub Release at `v0.6.0`, mark it Latest.
  - Use **`docs/releases/v0.6.0.md`** as the Release body (`gh release create v0.6.0 --notes-file docs/releases/v0.6.0.md`).
  - Upload all binary artifacts the previous releases (v0.5.2, v0.5.1) had — same naming convention (`sykli-{linux,macos}-{x86_64,aarch64}`).
- [ ] Verify `curl -fsSL https://raw.githubusercontent.com/yairfalse/sykli/main/install.sh | bash` installs the new binary and `sykli --version` reports `0.6.0`.

### CLAUDE.md (High — operating manual still says the old thing)

- [ ] Rewrite the `## What is Sykli?` section to match ADR-022. Drop the words "AI-native CI engine." The new lead sentence is the ADR-022 thesis: *"sykli is a compiler for programmable execution graphs."* CI is one use case.
- [ ] Keep the rest of the section's substance: SDKs, JSON task graph emission, BEAM execution, FALSE Protocol occurrences. Reframe them as consequences of the graph model, not as defining features of CI.

### README (High — multiple stale strings + missing commands + hero confusion)

- [ ] Update the hero terminal frame at the top of README.md (around line 34) — replace `local · 0.5.3` with `local · 0.6.0`.
- [ ] Update the SDK install table (around lines 165, 167):
  - `sykli = "0.5"` → `sykli = "0.6"`
  - `{:sykli_sdk, "~> 0.5.1"}` → `{:sykli_sdk, "~> 0.6.0"}`
  - Leave the unpinned rows (`go get …@latest`, `npm install sykli`, `pip install sykli`) alone.
- [ ] Add the three real CLI commands missing from the `## CLI` section: `sykli context`, `sykli query`, `sykli report`. Source of truth: `./core/sykli --help`. Do not invent commands; only add ones that exist.
- [ ] Resolve the "sykli review in the hero" confusion. The Go example block at the top (lines ~10–30) calls `sykli review --primitive api-breakage`, which is a roadmap-only command. Two acceptable resolutions, pick one:
  1. Keep the hero copy-pasteable: drop the `review` task from the hero example. Move it to a dedicated "Agentic review as code" section example below.
  2. Add an inline `// roadmap: ships in 0.6.x — see Roadmap section` comment immediately above the `s.Task("review")` line in the hero.

### Lockfile (High — committed package-lock.json points at 0.5.3)

- [ ] In `sdk/typescript/`, run `npm install` (no args) to regenerate `package-lock.json` against the new `0.6.0` package.json. Commit the regenerated lockfile.
- [ ] If `node_modules/` shows up in the diff, do not commit it; the existing `.gitignore` covers it.

### ADR housekeeping (Medium)

- [ ] Flip **ADR-022** from `**Status:** Proposed` to `**Status:** Accepted`. The README rewrite shipped; the repo About changed; treating the ADR as merely Proposed is dishonest about adopted state.
- [ ] **ADR-020** stays `Proposed` overall (its visual direction is still proposal-grade until promoted in a future ADR), but add a one-line note immediately below its Status line: `> Positioning section superseded by ADR-022 (2026-05-01). Visual direction remains canonical.` This makes the partial-supersedence visible to anyone reading ADR-020 cold.

### Workflow secret + slash command verification (Medium)

PR #132 added `claude.yml` and `claude-code-review.yml`. Verify both are wired correctly:

- [ ] Confirm the `CLAUDE_CODE_OAUTH_TOKEN` secret is set in repo Actions secrets. Run `gh secret list` to check. If missing, document it in the PR body and **do not silently assume it's set** — flag it.
- [ ] Open a tiny test PR (no-op edit, e.g., a typo fix in a comment) targeting `main` from a fresh branch to see whether `claude-code-review.yml` runs end-to-end. Verify `claude-code-review.yml`'s slash-command syntax (`prompt: '/code-review:code-review …'`) actually invokes a review run. If it errors, capture the error and surface it — do not "fix" it by changing the prompt format unless the error is unambiguous.

## Splitting

You may produce **one combined PR** (recommended for tight review) or **two PRs**:

1. `chore(release): tag v0.6.0 and ship binaries` — release tag, GitHub Release creation, binary uploads. No code or doc changes. Merges fast.
2. `docs: close v0.6 positioning + staleness gaps` — README + CLAUDE.md + ADRs + lockfile + workflow verification. Merges after #1.

If splitting, do them in that order. If combining, the title is `chore: complete v0.6.0 release + close docs gaps`.

## Out of scope — DO NOT TOUCH

- ✗ Any module under `core/lib/sykli/` (this is a release/docs pass, not feature work).
- ✗ Any new ADR (only edits to ADR-020 status note + ADR-022 status flip).
- ✗ Phase 2.5 findings (`eval/oracle/findings-phase-2-5.md`) — **separate Codex prompt remediates these**. Do not remove `expected_failure: true` from any case here.
- ✗ The PR review feature (`sykli review`) — separate Codex prompt builds it.
- ✗ Changes to `.github/workflows/release.yml`, `.github/workflows/sykli-ci.yml`, or `.github/workflows/ci.yml` unless you find them broken during the release run, in which case fix the smallest possible thing and document why.

## Conventions (from CLAUDE.md, non-negotiable)

- `mix format && mix test && mix credo && mix escript.build` before commit.
- No new dependencies.
- `~s()` parens gotcha; heredoc gotcha. Fixtures stay single-line where possible.
- Commits ending with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- Never push directly to `main`. Branch + PR only.

## Acceptance criteria

Every item below must be true before requesting review:

- [ ] `git tag --list | grep v0.6.0` returns the tag.
- [ ] `gh release list | head -1` shows `v0.6.0` as Latest.
- [ ] `curl -fsSL https://raw.githubusercontent.com/yairfalse/sykli/main/install.sh | bash` (run in a clean dir) installs a binary that reports `sykli 0.6.0`.
- [ ] `grep -E "0\.5\.3|0\.5\.1" README.md sdk/typescript/package-lock.json` returns nothing.
- [ ] `grep "AI-native CI" CLAUDE.md` returns nothing.
- [ ] `head -10 docs/adr/022-execution-graph-compiler-reframing.md | grep "Status:"` returns `Status: Accepted`.
- [ ] `head -10 docs/adr/020-positioning-and-visual-direction.md` includes the partial-supersedence note.
- [ ] `./core/sykli --help` and the README CLI section list the same commands.
- [ ] `cd core && mix test && mix credo` clean. `test/blackbox/run.sh` passes (any pre-existing `expected_failure` cases stay as they are — out of scope).
- [ ] Workflow secret check is documented in the PR body (set / missing / unverified).

## Anti-patterns — do not do these

- ✗ Don't merge the docs PR without tagging the release. The whole point is they go together.
- ✗ Don't ship binaries that don't pass `sykli --version` reporting `0.6.0`.
- ✗ Don't paper over the `claude-code-review.yml` slash-command issue if you find one — surface it.
- ✗ Don't touch any `expected_failure: true` case in `dataset.json`. **That is a different prompt's job.**
- ✗ Don't add a "review primitive" section to the README beyond what's already there. **That is a different prompt's job.**
- ✗ Don't auto-amend, don't `--no-verify`, don't bypass signing.

---

**End of prompt.** When this PR (or pair) merges, the v0.6.0 release is real, the docs match it, and the next two Codex prompts (Phase 2.5 fixes + PR review primitives) can run cleanly against a coherent baseline.
