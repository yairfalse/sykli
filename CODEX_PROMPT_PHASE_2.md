# Kickoff prompt for Codex — Phase 2: Webhook → Executor → Check Run Lifecycle

Paste the block below into Codex's chat to start Phase 2.

---

You are an engineering agent assigned to **Phase 2** of the GitHub-native CI rollout in the `sykli` repository (working directory: `/Users/yair/projects/sykli`, default branch: `main`, remote: `git@github.com:false-systems/sykli.git`).

**Project context.** Sykli is **local-first CI for the next generation of software developers**. Pipelines are written as code in any of five SDKs, emitted as JSON task graphs, and executed by an Elixir/BEAM engine. The v0.6 visual reset shipped in PR #123. **Phase 1 of v0.7 shipped in PR #125** — the GitHub App, webhook receiver, signature verification, replay LRU, Checks API client, and `:webhook_receiver` mesh role are all in place. A signed webhook now arrives at the user's mesh and produces a `queued` check suite + check run, then stops.

Your task is **Phase 2 only** — close the loop. The receiver hands off to the mesh, the source is acquired, the existing detector + executor run the pipeline, and per-task check runs transition through the GitHub Checks API lifecycle (`queued` → `in_progress` → conclusion). Phase 3 (PR diff annotations from `sykli fix`) and Phase 4 (App marketplace listing) come later. **Do not start them.**

**Read first, in order:**

1. **`CLAUDE.md`** — always-on operating manual. Build/test commands, conventions, the runtime isolation rule, the NoWallClock rule, the project principles (local-first, agents-as-executors), the §"OTP Supervision Tree" and §"Module Table" describe the Phase 1 surface you build on. Keep in working memory.
2. **What Phase 1 landed.** Run `git show 95a29d6` (the merge commit) and walk the per-commit log: `6f3414e` (App), `3587b20` (Signature/Deliveries), `2dfa9a9` (Checks), `c4a3190` (Mesh.Roles), `1f3fd3e` (Receiver + supervision), `bd99f53` (docs). You **build on** these; you do **not** rewrite them.
3. **`core/lib/sykli/github/`** — the Phase 1 module surface. Specifically:
   - `Sykli.GitHub.App.Behaviour` — `installation_token/2` (use this; do not roll your own)
   - `Sykli.GitHub.Checks` — `create_suite/3`, `create_run/4`, `update_run/4` (you will heavily use `update_run/4`)
   - `Sykli.GitHub.Webhook.Receiver` — Plug pipeline; you will extend its dispatch path
   - `Sykli.GitHub.Clock.Behaviour` — for any time math (no `DateTime.utc_now` direct calls)
4. **`core/lib/sykli/executor.ex`** — `Sykli.Executor.run/3` is the entry point. Its options + occurrence stream are your integration surface.
5. **`core/lib/sykli/detector.ex`** + **`core/lib/sykli/graph.ex`** — how a `sykli.{go,rs,ts,exs,py}` becomes a task DAG.
6. **`core/lib/sykli/occurrence.ex`** — the FALSE Protocol event factory. Phase 1 added `ci.github.webhook.received` and `ci.github.check_suite.opened`. You will add more.

**Critical context — the most likely places to misstep:**

- **Source acquisition is the new hard problem, and it is solvable cleanly.** When a webhook arrives, the receiver knows `repo_full_name` and `head_sha` but **not the source**. To run the pipeline, the source must land somewhere on the executing node. Use `git clone --depth 1` with the installation token as a Git credential: `https://x-access-token:<token>@github.com/<owner>/<repo>.git`, then `git -C <dir> checkout <head_sha>`. Clone into a unique temp directory under `System.tmp_dir!() <> "/sykli-runs/<run_id>/"`. **Always remove the directory on completion (success or failure)** via a process-monitor cleanup, not a try/after — the executing process may crash. Path containment rules from CLAUDE.md still apply: validate the resolved temp path is inside `System.tmp_dir!()` before any rm.
- **Per-task check runs, not one rolled-up run.** Each Sykli task is its own `check_run` inside one `check_suite` — this is the GitHub-native reporting contract. Phase 1 created the suite + a single placeholder run; **delete that placeholder pattern in this phase** and replace it with: one `check_run` per task in the parsed DAG, all created at `queued` before execution starts, then transitioned individually as the executor emits per-task occurrences.
- **The status mapping is fixed. Use exactly these.** Do not invent variants.

  | Sykli `TaskResult.status` | GitHub `check_run.conclusion` | Notes |
  |---|---|---|
  | `:passed`  | `success`   | The happy path |
  | `:failed`  | `failure`   | Command exited non-zero |
  | `:errored` | `failure`   | Mention "infrastructure failure" in `output.summary` |
  | `:cached`  | `success`   | Mention "(cache hit)" in `output.title` |
  | `:skipped` | `skipped`   | Condition not met |
  | `:blocked` | `cancelled` | Dependency failed |

  The check suite's overall conclusion is computed by GitHub from the runs; you do not need to set it manually.

- **The executor is single-source-of-truth for execution. Do not reimplement.** `Sykli.Executor.run/3` already takes a graph and emits occurrences via Phoenix.PubSub. Your job is to (a) build the graph from the cloned source via existing Detector/Graph modules, (b) subscribe to the occurrence stream for that `run_id`, (c) translate `ci.task.started` / `ci.task.completed` / `ci.task.cached` / etc. into Checks API calls. **Do not add a new Target. Do not add a new Runtime. Do not bypass the executor.**
- **Stay inside the runtime isolation rule.** No module outside `core/lib/sykli/runtime/` may name a specific runtime (`Docker`, `Podman`, `Shell`, `Fake`). The webhook dispatch path goes through `Sykli.Runtime.Resolver` like everything else; the executor handles runtime selection from there.
- **Default `:test` runtime is `Sykli.Runtime.Fake`.** Phase 2 tests must not require Docker, must not network out. Stub the GitHub API via the existing `Sykli.GitHub.HttpClient.Behaviour` (Phase 1 already split this) and the `Sykli.GitHub.App.Fake` already in the tree. Source-acquisition tests use a fixture local repo, not a real `git clone` — abstract clone behind a tiny behaviour (`Sykli.GitHub.Source.Behaviour`) with `Real` (`git clone`) and `Fake` (copy-from-fixture) impls.
- **NoWallClock Credo check** fails on `System.monotonic_time`, `System.os_time`, `DateTime.utc_now`, `:rand.uniform`, etc. Use `Sykli.GitHub.Clock` for any time math. Run IDs come from `Sykli.ULID`, never from `:erlang.now` or `make_ref`.
- **Don't break Phase 1's `queued`-only path on degraded configs.** If credentials are missing, the receiver must still 202 the webhook and emit `ci.github.webhook.received` — Phase 1's behavior. The Phase 2 dispatch is conditional on the App, source, and Checks client all being available; if any is not, log a structured warning and stop at `queued`.

**Phase 2 scope — what to build:**

A. **`Sykli.GitHub.Source` (behaviour) + `Sykli.GitHub.Source.Real` + `Sykli.GitHub.Source.Fake`** — clone a repo at a SHA into a unique temp dir, return `{:ok, path}` or `{:error, %Sykli.Error{}}`. Cleanup is explicit (`cleanup/1`). Real impl uses `git clone --depth 1` then `git checkout <sha>` with the installation token as auth. Fake impl copies from a test fixture directory. Path containment validated.

B. **`Sykli.GitHub.Dispatcher`** (`core/lib/sykli/github/dispatcher.ex`) — the orchestration glue between webhook and executor. Public API: `dispatch/2` taking `(webhook_event, opts)` and returning `:ok | {:error, %Sykli.Error{}}`. Steps: acquire installation token → acquire source → run Detector → emit graph via SDK → parse via `Sykli.Graph` → create one check run per task at `queued` → invoke `Sykli.Executor.run/3` → subscribe to occurrence stream for that run_id → translate to Checks API calls → cleanup source on terminal occurrence. The Dispatcher is process-supervised; one instance per webhook event, then exits.

C. **Receiver wiring.** Update `Sykli.GitHub.Webhook.Receiver` so the existing happy path (Phase 1) calls `Sykli.GitHub.Dispatcher.dispatch/2` asynchronously after returning 202. Use `Task.Supervisor.start_child` under the existing `Sykli.TaskSupervisor`, never `spawn`. The webhook response stays at 202 within the Phase 1 timing budget; dispatch happens out-of-band.

D. **Occurrence types.** Add to `Sykli.Occurrence`:
   - `ci.github.run.dispatched` — Dispatcher accepted the event and started orchestration
   - `ci.github.run.source_acquired` — clone succeeded, includes `path`, `sha`, `bytes`
   - `ci.github.run.source_failed` — clone failed, includes `error`
   - `ci.github.check_run.created` — per-task, includes `task_name`, `check_run_id`
   - `ci.github.check_run.transitioned` — `from`, `to`, `task_name`, `check_run_id`
   - `ci.github.check_suite.concluded` — terminal, includes `conclusion` from GitHub
   All emitted via the existing `Occurrence.PubSub`, never a new mechanism.

E. **Output rendering for check runs.** A small `Sykli.GitHub.CheckRunFormatter` module that turns a `TaskResult` + collected stdout/stderr into `{title, summary}` for `update_run/4`. Markdown summary. Phase 2 keeps it simple: title is the task name + `:passed`/`:failed`/etc., summary is the last ~50 lines of output in a fenced block. **Annotations on the PR diff are Phase 3 — do not add them here.**

F. **Documentation.** Update `docs/github-native.md` with the Phase 2 section: how a webhook now produces real check runs, what the user will see in the PR's Checks tab, how to read a failure summary, and the env vars + GitHub App permissions that change (you will need `contents:read` for the source clone — verify this is in the documented permissions list and update if not).

**Out of scope — DO NOT TOUCH:**

- ✗ PR diff annotations (per-file, per-line) from `sykli fix`. **Phase 3.**
- ✗ Re-run from the GitHub UI (handling `check_run.rerequested` events). Phase 3.
- ✗ App marketplace listing, manifest publishing. Phase 4.
- ✗ The legacy `Sykli.SCM.GitHub` Commit Status API path. Stays as-is.
- ✗ The visual reset modules (`Sykli.CLI.Renderer/Theme/Live/FixRenderer`). Untouched.
- ✗ The JSON envelope (`Sykli.CLI.JsonResponse`). Untouched.
- ✗ Adding a new `Target` or `Runtime`. The executor already has these.
- ✗ Webhook delivery ordering reconciliation. Open question, defer.
- ✗ Multi-mesh installation disambiguation. Open question, defer.
- ✗ Caching across runs. The existing `Sykli.Cache` already handles this; you don't add cache logic.

**Conventions (from CLAUDE.md, non-negotiable):**

- Behaviours over protocols. `Source.Behaviour` with `Real` + `Fake`. Same pattern Phase 1 used.
- Structured errors via `Sykli.Error` — codes like `github.dispatch.no_pipeline`, `github.source.clone_failed`, `github.checks.update_failed`. Never bare strings.
- `:httpc` callers use `Sykli.HTTP.ssl_opts/1`. Phase 1's `Sykli.GitHub.HttpClient` already does this; reuse it for Checks API calls.
- `run_id` threaded explicitly through Dispatcher → Executor → occurrence emission. Never `Process.put`.
- Stateless modules; no new GenServers unless absolutely necessary. The Dispatcher is one short-lived `Task` per webhook, not a long-running server.
- `mix format && mix test && mix credo && mix escript.build` before every commit.
- Path containment for the source temp dir: validate via `String.starts_with?(resolved, base <> "/")`.
- Secret masking applies to occurrence data via `Sykli.Services.SecretMasker.mask_deep/2` — installation tokens must never appear in occurrence payloads.

**Implementation sequence:**

1. Branch from `main`: `git checkout main && git pull && git checkout -b feat/github-native-phase-2`.
2. Build `Sykli.GitHub.Source` (behaviour + Real + Fake) with tests. Real shells out to `git`; Fake copies from `test/fixtures/github_source/<scenario>/`. Add a couple of fixture repos with `sykli.exs` files.
3. Add the new occurrence factory functions to `Sykli.Occurrence`.
4. Build `Sykli.GitHub.CheckRunFormatter` with table-driven tests (one row per Sykli status).
5. Build `Sykli.GitHub.Dispatcher` with tests using the Fake source and the existing GitHub Fakes. Test the happy path, the per-task transition path, and three failure modes (clone fails, no pipeline file detected, executor crashes).
6. Wire `Sykli.GitHub.Webhook.Receiver` to call `Dispatcher.dispatch/2` via `Task.Supervisor`. Verify the receiver still returns 202 within ~50ms even when dispatch takes longer.
7. Update `docs/github-native.md` with Phase 2 changes (new App permission `contents:read`, new occurrences, new screenshot of the PR's Checks tab with per-task runs).
8. Run the full pre-commit gate: `cd core && mix format && mix test && mix credo && mix escript.build`. Then `test/blackbox/run.sh` from the repo root.
9. Commit in logical chunks:
   - `feat(github): add Source behaviour with Real (git clone) and Fake (fixture)`
   - `feat(github): add check-run formatter with status mapping`
   - `feat(occurrence): add Phase 2 GitHub-native occurrence types`
   - `feat(github): add Dispatcher (webhook → source → executor → checks)`
   - `feat(github): wire receiver to async dispatch via TaskSupervisor`
   - `docs: update github-native walkthrough for Phase 2`
10. Push and open PR titled **`feat(github): Phase 2 — Webhook → Executor → Check Run Lifecycle`**. Body: 1-line summary + bulleted scope + a screenshot of a real PR's Checks tab showing per-task runs from a webhook-triggered run.

**Acceptance criteria:**

- [ ] `mix test`, `mix credo` (NoWallClock satisfied), `mix format` clean.
- [ ] `mix escript.build` produces a working binary; `./core/sykli --help` unchanged.
- [ ] `test/blackbox/run.sh` passes all cases (no regressions to the visual reset).
- [ ] An `@tag :integration` test demonstrates the full loop against a fixture repo + GitHub Fakes: signed webhook → 202 → source acquired → DAG built → check runs created → executor runs → check runs transitioned → check suite concluded → temp directory cleaned up.
- [ ] A negative-path test demonstrates: webhook arrives, source clone fails → check suite concludes `failure` with a useful summary, temp directory cleaned up regardless.
- [ ] `Sykli.SCM.GitHub` (the fallback Commit Status path) is **untouched** and its existing tests still pass unchanged.
- [ ] The Phase 1 `queued`-only behavior is preserved when env is degraded (App credentials missing): receiver still 202s, `ci.github.webhook.received` still emits, dispatch is skipped with a structured warning.
- [ ] No new top-level deps unless justified in the PR body. (You should not need any.)
- [ ] Installation tokens never appear in any occurrence payload (verified by a test that asserts `mask_deep` was applied to the Dispatcher's emissions).
- [ ] `docs/github-native.md` walks the user from a fresh App install through a successful webhook-triggered run with per-task check runs visible on the PR.

**Anti-patterns — do not do these:**

- ✗ Don't `spawn/1` the Dispatcher. Use `Task.Supervisor.start_child` under `Sykli.TaskSupervisor`. Crashes must not silently disappear.
- ✗ Don't shell out to `git` from the Dispatcher directly. The clone goes through `Sykli.GitHub.Source.Real` which is the only place naming `git`. Tests use the `Fake`.
- ✗ Don't introduce a long-running GenServer to "manage all dispatches." One `Task` per webhook, then exit. State (if any) lives in ETS or `:persistent_term`, not in process state.
- ✗ Don't silently swallow Checks API errors. If `update_run/4` fails, log structured + emit `ci.github.check_run.transition_failed` (you can add this occurrence) and let the executor continue. The check run drift is recoverable; killing the run is not.
- ✗ Don't put installation tokens in stack traces, occurrence payloads, or log messages. Mask before serializing.
- ✗ Don't auto-amend commits, don't `--no-verify`, don't bypass signing.
- ✗ Don't add comments explaining what code does. WHY only, when non-obvious. No multi-paragraph docstrings.
- ✗ Don't add a feature flag toggling old vs new behavior. The legacy SCM path lives on its own; this is purely additive.
- ✗ Don't dispatch synchronously from the webhook handler. The 202 is part of the contract.

**Things to ask if you can:**

- Should the Dispatcher run on the receiver node, or on a node placed via `Sykli.Mesh.Roles` / capability rules? Default for Phase 2: **on the receiver node** (single-node mesh is the common case). Multi-node placement is a Phase 3 concern.
- Output summary line count? Default: **last 50 lines of stdout/stderr per task**, in a fenced ```` ```text ```` block.
- Source temp directory retention on success? Default: **delete immediately**. (Failures: also delete; the source is in GitHub.)
- `git clone` shallow depth? Default: **`--depth 1`**, then `git fetch --depth 1 origin <sha>` if the SHA isn't on the default branch.
- New App permission `contents:read` — do we update the App manifest in this PR, or leave that as a doc-only change for the operator? Default: **doc-only update in `docs/github-native.md`**. Manifest changes happen out-of-band when the operator re-installs.

If you cannot ask, use the defaults.

---

**End of Phase 2 prompt.** When this PR is merged, Phase 3 picks up the `sykli fix` integration: per-file, per-line annotations rendered onto the PR diff via the Checks API's annotation surface. Do not start Phase 3 in this PR.
