# Codex prompt — PR review primitives (`sykli review`) for v0.6.x

Paste the block below into Codex's chat to start.

---

You are an engineering agent assigned to **building the `sykli review` command and its first five primitives**, the headline new feature of v0.6.x. The command is referenced in the README ("Agentic review as code") and the Roadmap, and is the canonical way reviews become first-class graph nodes per CLAUDE.md §"Project principles" — *agents are executors inside the graph, not magical reviewers*.

This is a **substantial feature build** — more than a single Codex run might fit. **Scope it as three commits**, all on one branch, in one PR titled `feat(review): sykli review with five primitives (v0.6.x)`. Ship it as `v0.6.1`. **Take no prisoners.** No demoware, no half-implemented primitives, no hand-waving on the agent-executor abstraction.

This prompt assumes:

1. **PR #127's release-and-docs cleanup has merged** — `v0.6.0` is tagged, README and CLAUDE.md reflect the execution-graph positioning, the package-lock is fresh.
2. **The Phase 2.5 remediation pass has merged** — `expected_failure: true` is gone from `dataset.json`, all 11 findings closed.

If those baselines are not in place, **stop and surface it.** Do not proceed against an inconsistent main.

## Mission

Implement `sykli review` with five primitives, structured outputs, and an agent-executor abstraction. The command is the first place where the project's claim — *"agents are executors inside the graph, not magical reviewers"* (CLAUDE.md §Project principles) — becomes code.

## Read first, in order

1. **`CLAUDE.md`** at repo root — always-on operating manual. Conventions, JSON envelope, runtime isolation rule, NoWallClock rule, project principles (the *agents are executors* framing).
2. **`README.md` "Agentic review as code" section** — the user-visible promise the implementation must fulfill. The Roadmap names the five primitives that ship in this PR.
3. **`core/lib/sykli/cli.ex`** — command dispatch surface. You will add a `review` branch.
4. **`core/lib/sykli/cli/json_response.ex`** — the shared envelope. `sykli review --json` flows through it.
5. **`core/lib/sykli/fix.ex` + `core/lib/sykli/fix/output.ex`** — closest existing analog. `sykli fix` reads the latest occurrence and renders structured analysis. Your `sykli review` reads a diff and renders structured findings. Same shape, different input source.
6. **`core/lib/sykli/git.ex` and `core/lib/sykli/git_context.ex`** — diff and git-state utilities. Reuse them.

(Note: a separate Phase 3 effort handles `sykli fix` / review-result annotations on the PR diff via the GitHub Checks API. Your work is *adjacent* but distinct: review primitives are produced by `sykli review`; Checks API integration is a separate path. Don't duplicate.)

## Critical context — the most likely places to misstep

- **A primitive is a typed contract, not a prompt.** Every primitive declares: name, input schema, output schema (JSON Schema), executor type. The `Sykli.Review.Primitive` struct is the runtime carrier. The prompt-template-for-an-LLM is one *implementation* of a primitive's executor — not the primitive itself. Confusing the two will produce code that's "send this to Claude with this prompt" instead of "fulfill this contract however you can."
- **Agents are executors, not the system.** The five primitives ship with **deterministic default executors** that produce real output without an LLM. Claude / Codex / local models can replace any executor, but the default ships green. *No primitive may require an external API to be useful.*
- **Output is structured JSON, not prose.** Each primitive emits a JSON document conforming to the primitive's output schema. A free-text "summary" field is allowed; *all other fields are typed.* The graph-node consumer reads JSON; the human consumer reads a rendered terminal frame derived from the JSON.
- **Reviews are graph nodes; the command is the executor.** The user adds `s.Task("review/security").Run("sykli review --primitive security --diff main...HEAD").Outputs("security.json")` to their `sykli.go`. Sykli executes it like any other task. The task's output file is the structured review. Other tasks can `InputFrom(...)` it.
- **Don't reach for the GitHub API.** The Checks API integration of these reviews is **not in this PR**. The GitHub-native Phase 3 effort owns that. Your `sykli review` writes JSON to disk and stdout; it does not call GitHub. Period.
- **Default `:test` runtime is `Sykli.Runtime.Fake`.** Tests do not call out to real LLMs, do not network. If a primitive's default executor needs HTTP, it goes through `Sykli.HTTP.ssl_opts/1` and is mocked in tests via behaviour-split — same pattern as `Sykli.GitHub.HttpClient`.
- **NoWallClock + runtime isolation still apply.** Routing time through the existing `Sykli.GitHub.Clock`-style behaviour split is acceptable; rolling your own `:os.system_time/0` is not.

## Scope — the three commits

This work is one PR, three commits, in this order. Each commit is independently buildable + tested.

### Commit 1: spec doc + primitive contract module

Title: `feat(review): add Sykli.Review.Primitive contract and spec doc`

Files:
- `docs/reviews.md` — authoritative spec for the feature. Sections:
  - Context: reviews are graph nodes per CLAUDE.md §"Project principles" (*agents are executors, not reviewers*); this doc specifies what a primitive is.
  - Decision: a Primitive is `{name, version, input_schema, output_schema, default_executor, optional_executors}`. The `sykli review` command resolves a primitive name → executor → produces output.
  - The five primitives' purposes, input fields, and output schemas (one paragraph each + JSON Schema fragment).
  - The executor abstraction: `Sykli.Review.Executor.Behaviour` with `run/2` returning `{:ok, Sykli.Review.Result.t()} | {:error, %Sykli.Error{}}`. Implementations: `.Deterministic` (default), `.Claude`, `.Codex`. Selection by env (`SYKLI_REVIEW_EXECUTOR=deterministic|claude|codex`) or `--executor` flag.
  - Out of scope (this v0.6.x ship): the Checks API rendering of review outputs (Phase 3 of the GitHub-native effort); review primitive marketplace; multi-agent-disagreement aggregation.
- `core/lib/sykli/review.ex` — public API: `Sykli.Review.run(primitive_name, opts)`, `Sykli.Review.list_primitives/0`, `Sykli.Review.Primitive` struct.
- `core/lib/sykli/review/primitive.ex` — the struct.
- `core/lib/sykli/review/result.ex` — the result struct (carries the JSON output + metadata).
- `core/lib/sykli/review/executor/behaviour.ex` — the behaviour.
- `core/lib/sykli/review/executor/deterministic.ex` — base impl that primitives default to.
- `core/lib/sykli/review/registry.ex` — name → primitive mapping. ETS-backed at app start.
- Tests: `core/test/sykli/review/primitive_test.exs`, `registry_test.exs`, `executor/behaviour_test.exs` covering: registry registration, primitive validation, executor behaviour contract.

This commit ships **no primitives yet** and **no CLI command**. Just the contract, the registry, and the spec doc. Foundation only. (Commit 3 will expand `docs/reviews.md` with usage walkthroughs and the dogfood section.)

### Commit 2: Five primitives + CLI command

Title: `feat(review): add sykli review CLI and five primitives`

Files:
- `core/lib/sykli/review/primitives/security.ex` — `review/security`. Inputs: diff range. Output: `{summary, severity, findings: [{file, line, kind, evidence, suggested_fix}]}`. Default executor scans the diff for hard-coded secrets via pattern matching (reuse `Sykli.Services.SecretMasker` patterns) + obvious smells (curl piped to bash, eval(env), `--insecure`, etc.). Pure deterministic.
- `core/lib/sykli/review/primitives/api_breakage.ex` — `review/api-breakage`. Inputs: diff range, optional language hint. Output: `{summary, breakages: [{symbol, kind, before, after, severity}]}`. Default executor walks the diff hunks looking for removed/renamed exported symbols by simple language-aware pattern (Go: `^func [A-Z]`, `^type [A-Z]`; Elixir: `def `, `defp ` distinction; etc.). Pure deterministic.
- `core/lib/sykli/review/primitives/observability_regression.ex` — `review/observability-regression`. Inputs: diff range. Output: `{summary, regressions: [{kind, file, line, evidence}]}`. Default executor flags removed `Logger.*` calls, removed `:telemetry.execute` calls, removed structured fields. Pure deterministic.
- `core/lib/sykli/review/primitives/test_coverage_gap.ex` — `review/test-coverage-gap`. Inputs: diff range. Output: `{summary, gaps: [{file, kind, evidence}]}`. Default executor flags new functions/modules in the diff that have no corresponding test file changes (heuristic: every `lib/foo/bar.ex` change should have a `test/foo/bar_test.exs` change in the same diff).
- `core/lib/sykli/review/primitives/architecture_boundary.ex` — `review/architecture-boundary`. Inputs: diff range. Output: `{summary, violations: [{from, to, rule, evidence}]}`. Default executor checks the existing runtime-isolation invariant + a small declarative ruleset in `core/config/architecture.exs`: e.g., "no module under `cli/` may import a `runtime/` module by class name." Reuses `Sykli.Runtime.Resolver`-style isolation tests.
- CLI wiring: `core/lib/sykli/cli.ex` adds `["review" | review_args]` branch dispatching to `Sykli.CLI.Review.run/1`. New module `core/lib/sykli/cli/review.ex` parses flags (`--primitive`, `--diff`, `--executor`, `--json`, `--output`), calls `Sykli.Review.run/2`, renders.
- Renderer: `core/lib/sykli/cli/review_renderer.ex` — terminal output for review results. Follow CLAUDE.md §"CLI output rules": glyphs, accent color, no banned vocabulary. Failure mode (severity ≥ medium) draws a horizontal rule and shows a per-finding block. Stdout JSON via `Sykli.CLI.JsonResponse`.
- Tests: per-primitive deterministic tests against fixture diffs in `core/test/fixtures/review/<primitive>/`. Each fixture is a `.diff` file and the expected output JSON.
- One end-to-end black-box case per primitive in `test/blackbox/dataset.json` (`REVIEW-001..005`), each with `expected_exit: 0` and `expect_json_keys: ["ok", "version", "data", "error"]` plus a primitive-specific jq assertion.

### Commit 3: Documentation, dogfood, and roadmap update

Title: `docs(review): wire sykli review into README, CLAUDE.md, and the dogfood pipeline`

Files:
- `README.md` — replace the "Agentic review as code" section's example with **the now-real** code path. Drop the inline "roadmap" caveat from the example since the command exists. Update the Roadmap section: review primitives moves from "in development" to shipped in 0.6.x.
- `CLAUDE.md` — add a `Sykli.Review` row to the Key Modules table. Add a brief "Review primitives" subsection under Project principles explaining the contract and the Default→Claude→Codex executor chain. No more than 15 lines.
- `docs/reviews.md` — *expand* the spec doc that Commit 1 created: add usage walkthroughs (how to add a primitive, how to swap an executor), per-primitive JSON Schema reference, env vars (`SYKLI_REVIEW_EXECUTOR`, primitive-specific overrides). After expansion: ~100 lines.
- `sykli.exs` (the dogfood pipeline at repo root) — add a `review/security` task wired into the build to dogfood the feature on every CI run.
- `CHANGELOG.md` — new `[0.6.1]` entry under Added: review primitives feature, five primitives, executor abstraction.

## Out of scope — DO NOT TOUCH

- ✗ Calling the Checks API to upload review results to GitHub. **GitHub-native Phase 3.** This PR's `sykli review` writes JSON to disk + stdout, full stop.
- ✗ Calling Claude / Codex / any external LLM API in this PR. The `.Claude` and `.Codex` executor modules are stubs that return `{:error, :not_implemented}` — they exist to prove the abstraction; they will be wired in a follow-up PR with proper auth + cost handling.
- ✗ Adding new primitives beyond the five named. Six or seven seems "easy" — it's not. Each primitive is a long-lived contract.
- ✗ The webhook receiver, Phase 2 dispatch path, anything under `core/lib/sykli/github/`. Untouched.
- ✗ The visual reset modules (`Sykli.CLI.Renderer/Theme/Live/FixRenderer`). Reuse the Theme; do not modify.
- ✗ The runtime decoupling (`Sykli.Runtime.*`). Untouched.
- ✗ Adding `sykli review` as a runnable task on a node that doesn't have `git` available. Document the dependency; don't try to bundle git.
- ✗ Re-introducing `expected_failure: true` for any new known-broken behavior. Open issues instead.

## Conventions (from CLAUDE.md, non-negotiable)

- Behaviour + Real + Fake split for the executor layer.
- Structured `Sykli.Error` codes: `review.primitive.unknown`, `review.diff.invalid`, `review.executor.unavailable`, etc.
- `:httpc` callers — `Sykli.HTTP.ssl_opts/1`. Not relevant for the deterministic executors but applies to the Claude/Codex stubs.
- Stateless modules where possible. The registry is one ETS table at app start; primitives are pure functions. No GenServer per primitive.
- `mix format && mix test && mix credo && mix escript.build` clean.
- All commits end with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

## Implementation sequence

1. Verify the baseline: `git rev-parse v0.6.0` resolves; `grep '"expected_failure": true' test/blackbox/dataset.json` returns nothing; CLAUDE.md contains a §"Project principles" section. **If any of these fail, STOP** and surface that the prerequisite Codex prompts haven't completed.
2. Branch: `git checkout main && git pull && git checkout -b feat/review-primitives`.
3. Commit 1: spec doc + contract modules + registry + behaviour + deterministic-base. Tests for the contract surface only (no primitives yet).
4. Commit 2: five primitive modules + CLI wiring + renderer + per-primitive fixture tests + black-box `REVIEW-*` cases.
5. Commit 3: README + CLAUDE.md + `docs/reviews.md` + dogfood pipeline + `[0.6.1]` CHANGELOG entry.
6. Pre-PR gate: `cd core && mix format && mix test && mix credo && mix escript.build`. Then `test/blackbox/run.sh` and `tests/conformance/run.sh`. All clean.
7. Push, open PR `feat(review): sykli review with five primitives (v0.6.x)`. Body: 1-line summary; bulleted scope per commit; a screenshot of `sykli review --primitive security --diff HEAD~3...HEAD --json | jq '.data'` output run against the repo itself.
8. After the PR merges, follow up with: `mix.exs` bump to `0.6.1`; SDK manifest bumps to `0.6.1`; CHANGELOG date stamp; tag `v0.6.1`; `gh release create v0.6.1 --notes-file docs/releases/v0.6.1.md` (write that release-notes file as part of this commit chain or a follow-up — your call, document in the PR which).

## Acceptance criteria

- [ ] `./core/sykli review --help` prints usage with the five primitive names and the `--executor`, `--diff`, `--primitive`, `--json`, `--output` flags.
- [ ] `./core/sykli review --primitive security --diff HEAD~3...HEAD --json` (run on the sykli repo itself) emits a valid JSON envelope with primitive-specific data.
- [ ] All five primitives pass their fixture tests under `mix test`.
- [ ] All five `REVIEW-001..005` black-box cases pass without `expected_failure`.
- [ ] **`SYKLI_REVIEW_EXECUTOR=claude sykli review …`** returns `{ok: false, error: {code: "review.executor.unavailable", …}}` cleanly — the stub is honest about not being wired.
- [ ] **`SYKLI_REVIEW_EXECUTOR=deterministic`** is the default; running with no env var produces the same output as setting it explicitly.
- [ ] `mix credo` (NoWallClock satisfied), `mix format` clean.
- [ ] `tests/conformance/run.sh` still passes for all five SDKs.
- [ ] `docs/reviews.md` is the authoritative spec for the feature. README's "Agentic review as code" example is now copy-paste-runnable. Roadmap updated. CLAUDE.md updated.
- [ ] The dogfood `sykli.exs` pipeline includes a `review/security` task and that task passes on a clean main.
- [ ] No call to a real LLM API made anywhere in test or default execution paths.

## Anti-patterns — do not do these

- ✗ Don't ship a primitive whose default executor returns `{:error, :requires_llm}`. Every primitive must produce useful output without an external API. **No demoware.**
- ✗ Don't make the Claude/Codex stubs *do* anything. They exist to prove the abstraction. Wiring them is a follow-up PR with explicit cost/auth design.
- ✗ Don't smuggle "send this prompt to an LLM" logic into a deterministic executor. If a primitive can only be useful with an LLM, the primitive is wrong-sized for v0.6.x — defer it.
- ✗ Don't make `sykli review` post to GitHub. JSON to stdout/disk, full stop. The Checks API path is the GitHub-native Phase 3 effort.
- ✗ Don't introduce a new logging library, a new HTTP library, or a new schema validator. Use what's in `mix.lock`. JSON Schema validation can be done with simple pattern matching for v0.6.x; full schema enforcement is a follow-up.
- ✗ Don't bundle this with the release-and-docs cleanup or the Phase 2.5 fixes. **Three separate prompts, three separate PRs.** Confirm baselines before starting.
- ✗ Don't `expected_failure` your way out of a hard test. If a primitive can't handle a corner case, fix it or deliberately defer it via a documented limitation in `docs/reviews.md`.
- ✗ Don't auto-amend, don't `--no-verify`, don't bypass signing.

## Things to ask if you can

- Should `sykli review --primitive security` exit non-zero when severity ≥ medium, like a linter, or always exit 0 with severity in the JSON? **Default: exit 0 always; severity is in the data.** Graph nodes consume the JSON; non-zero exit is the graph engine's job to interpret per-task.
- Should the deterministic security executor ship with a regex set inline or load from `core/config/review_security.exs`? **Default: inline + override via config file.** Easy to override, no required config.
- Should `sykli review` cache its outputs by diff hash? **Default: no for v0.6.x.** Reviews are quick; caching adds invalidation complexity. Defer.
- For `review/test-coverage-gap`, the heuristic is fragile (file naming convention). Should it support a project-specific mapping? **Default: yes, via `core/config/review_coverage.exs` with `{lib_path_pattern, test_path_pattern}` pairs.** Default mapping covers Elixir + Go conventions.

If you cannot ask, use the defaults.

---

**End of prompt.** This is the v0.6.x feature ship. After this PR merges + 0.6.1 tags, the project's positioning ("agents are executors inside the graph") has its first concrete implementation, and the next phase (GitHub-native Phase 3 — review annotations on the PR diff via Checks API) has a real artifact to render.
