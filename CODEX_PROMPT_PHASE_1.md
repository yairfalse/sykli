# Kickoff prompt for Codex — Phase 1: GitHub-Native Foundation

Paste the block below into Codex's chat to start Phase 1.

---

You are an engineering agent assigned to **Phase 1** of the GitHub-native CI rollout in the `sykli` repository (working directory: `/Users/yair/projects/sykli`, default branch: `main`, remote: `git@github.com:false-systems/sykli.git`).

**Project context.** Sykli is **local-first CI for the next generation of software developers** (ADR-020). Pipelines are written as code in any of five SDKs (Go, Rust, TypeScript, Elixir, Python), emitted as JSON task graphs, and executed by an Elixir/BEAM engine. The v0.6 visual reset shipped in PR #123 — the CLI now looks like Linear/Vercel, not a mix task. The next line is **replacing the in-Actions integration (ADR-004) with a GitHub-native receiver running on the user's own mesh (ADR-021).** Future phases (Phase 2: pipeline dispatch from webhooks, Phase 3: PR diff annotations from `sykli fix`, Phase 4: App marketplace listing) build on this foundation.

Your task is **Phase 1 only** — the plumbing that proves the loop end-to-end, without dispatching a real pipeline yet. A webhook arrives at the user's mesh, signature is verified, an installation token is acquired, a Check Suite is opened on the PR with status `queued`, the receiver logs success. Phase 2 (pipeline dispatch) starts only after Phase 1 lands and is reviewed.

**Read first, in order:**

1. **`CLAUDE.md`** — always-on operating manual. Build/test commands, conventions, patterns. Keep in working memory.
2. **`docs/adr/021-github-native-via-webhook-mesh-receiver.md`** — authoritative spec for this entire rollout. Read in full.
3. **`docs/adr/020-positioning-and-visual-direction.md`** — the local-first commitment that constrains every decision in Phase 1. Specifically the "ruled in" / "ruled out" lists.
4. **`docs/adr/004-github-integration.md`** — superseded v1 design. Read to understand what stays as the documented fallback (the Commit Status API path via `core/lib/sykli/scm/github.ex`).
5. **`docs/adr/006-local-remote-architecture.md`** — Accepted. Reinforces the receiver-as-mesh-peer model. The receiver is **not** a service.
6. **`docs/adr/017-task-placement.md`** — placement model for capability-labeled nodes. The `:webhook_receiver` role uses this.
7. **What just landed.** Run `git show 067aa96` (Theme/Renderer/Live modules) and `git log --oneline 067aa96..HEAD` to understand the v0.6 visual reset Codex just shipped — you must not regress its output.
8. **`core/lib/sykli/scm/github.ex`** + **`core/lib/sykli/mesh/transport.ex`** + **`core/lib/sykli/mesh/transport/erlang.ex`** — the existing GitHub client (legacy, stays as fallback) and the mesh transport you will register a new role within.

**Critical context — the most likely places to misstep:**

- **The receiver is a node in the user's OTP cluster, not a service.** Do not build a Phoenix application. Do not start a long-running supervisor that owns "the GitHub state." It is a small Plug pipeline + an HTTP listener (Bandit), supervised by `Sykli.Application`, only active on the node holding the `:webhook_receiver` capability label. Idle on every other node. ADR-021 §"Topology" + ADR-006 are non-negotiable.
- **GitHub App ≠ OAuth ≠ PAT.** Authentication is via a GitHub App's installation token (1-hour TTL). The flow: load the App's RSA private key from `SYKLI_GITHUB_APP_PRIVATE_KEY` (file path or PEM literal) → mint a JWT with `iat`, `exp`, `iss=app_id` claims, signed RS256 → `POST /app/installations/:installation_id/access_tokens` with the JWT as bearer → cache the resulting installation token for ≤55 minutes. ADR-021 §"Why GitHub App, not OAuth or PAT" + the table.
- **Verify webhook signatures before any processing.** `X-Hub-Signature-256` is HMAC-SHA256 over the raw body, keyed by the App's webhook secret. Constant-time compare. **Reject mismatches without logging the body.** Hard requirement, ADR-021 §"Security." Replay protection: maintain an LRU of `X-GitHub-Delivery` IDs (default 10k entries, 24h TTL) and reject duplicates.
- **Checks API, not Commit Status API.** Per-task entities are *check runs* inside a *check suite*. Phase 1 only needs check-suite creation + a single placeholder check run with status `queued`. The legacy `Sykli.SCM.GitHub` Commit Status path stays in the codebase as the fallback for users who can't expose an endpoint — **do not delete it, do not rewrite it, do not call it from the new path**.
- **Default `:test` runtime is `Sykli.Runtime.Fake`.** Your tests must not require Docker, must not network out. Tag any test that does with `@tag :integration`. Stub the GitHub API by binding a localhost HTTPS server in tests, or by passing a behaviour-based client into the modules under test (the latter is preferred — see `Sykli.Runtime.Behaviour` for the pattern).
- **The custom `CredoSykli.Check.NoWallClock` check** fails on `System.monotonic_time`, `System.os_time`, `System.system_time`, `DateTime.utc_now`, `NaiveDateTime.utc_now`, `:os.system_time`, `:erlang.now`, and bare `:rand.uniform`. JWT `iat`/`exp` claims and token expiry tracking must use a deterministic time source. Define a tiny `Sykli.GitHub.Clock` behaviour with a default real-time impl and a Fake for tests, or accept time as an argument.
- **Don't touch the JSON envelope, the occurrence pipeline, or the visual reset.** The receiver emits occurrences via the existing `Sykli.Occurrence` factory — `ci.github.webhook.received`, `ci.github.check_suite.opened` — broadcast on Phoenix.PubSub like any other event. The CLI surfaces are unchanged in Phase 1.

**Phase 1 scope — what to build:**

A. **`Sykli.GitHub.App`** (`core/lib/sykli/github/app.ex`) — JWT signing for App auth, installation token acquisition + caching, behaviour split (`Real` + `Fake` for tests). Public API: `installation_token/1` returning `{:ok, token, expires_at}` or `{:error, %Sykli.Error{}}`.

B. **`Sykli.GitHub.Webhook.Receiver`** (`core/lib/sykli/github/webhook/receiver.ex`) — Plug pipeline mounted on Bandit. Endpoints: `POST /webhook` (signature-verify, replay-check, dispatch), `GET /healthz` (200 if the node holds the role, 503 otherwise). Signature verification + replay LRU live in dedicated submodules (`Webhook.Signature`, `Webhook.Deliveries`).

C. **`Sykli.GitHub.Checks`** (`core/lib/sykli/github/checks.ex`) — Checks API client. Phase 1 surface: `create_suite/2`, `create_run/3` (status `queued`), `update_run/3` (for Phase 2 to use). Uses `:httpc` with `Sykli.HTTP.ssl_opts/1`.

D. **`Sykli.Mesh.Roles`** (`core/lib/sykli/mesh/roles.ex`) — Capability label registry. Public API: `acquire/1`, `release/1`, `holder/1`. Single-node-per-role placement rule via the existing transport. Application supervisor consults it before starting the Receiver.

E. **Wire it together: the Phase 1 happy-path loop.** A webhook arrives → `Receiver` verifies signature → looks up the installation → calls `App.installation_token/1` → calls `Checks.create_suite/2` for the head SHA → broadcasts `ci.github.webhook.received` and `ci.github.check_suite.opened` occurrences → returns 202. **No pipeline runs in this phase.** The check suite stays at `queued` status until Phase 2.

F. **Documentation.** A new `docs/github-native.md` walking a user from "I have a sykli mesh on my laptop" to "PR shows a queued check from sykli." Cover: registering the App, granting permissions (`checks:write`, `metadata:read`, `pull_requests:read`), webhook events to subscribe to (`push`, `pull_request`, `check_run`), exposing the endpoint (Tailscale Funnel, Cloudflare Tunnel, public IP + TLS), and the four required env vars (`SYKLI_GITHUB_APP_ID`, `SYKLI_GITHUB_APP_PRIVATE_KEY`, `SYKLI_GITHUB_WEBHOOK_SECRET`, `SYKLI_GITHUB_RECEIVER_PORT`).

**Out of scope — DO NOT TOUCH:**

- ✗ Pipeline dispatch from webhook → mesh placement → executor → check run lifecycle. **That is Phase 2.** The check suite created in Phase 1 stays at `queued` forever; Phase 2 transitions it.
- ✗ `sykli fix` annotations on PR diff. Phase 3.
- ✗ App marketplace listing, Terraform/Pulumi modules. Phase 4 or beyond.
- ✗ The fallback `Sykli.SCM.GitHub` Commit Status API path. Stays as-is.
- ✗ Webhook delivery ordering reconciliation. Open question per ADR-021.
- ✗ Multi-mesh installation disambiguation. Open question per ADR-021.
- ✗ Light-mode terminal palette. Out of scope across the whole v0.7 line.
- ✗ ADR-020/021/004 themselves. **Do not edit ADRs in implementation PRs.**
- ✗ The visual reset modules (`Sykli.CLI.Renderer`, `Theme`, `Live`, `FixRenderer`). Untouched.
- ✗ The JSON envelope (`Sykli.CLI.JsonResponse`). Untouched.

**Conventions (from CLAUDE.md, non-negotiable):**

- Behaviours over protocols. `Sykli.GitHub.App.Behaviour` with `Real` and `Fake` impls.
- Structured errors via `Sykli.Error` — never bare strings. Use `Sykli.Error.with_code/3` patterns already in the repo.
- `:httpc` callers must include `Sykli.HTTP.ssl_opts/1`. The Checks API client must.
- `run_id` is threaded explicitly through executor functions; never use the Process dictionary.
- Services are stateless modules in `services/`; pure functions where possible.
- `~s()` with parens gotcha: use `~s[]` or `~S||` for strings containing parens. Heredoc `"""` embeds literal newlines.
- `mix format && mix test && mix credo && mix escript.build` before every commit. The custom `NoWallClock` check is part of `mix credo`.

**Implementation sequence:**

1. Branch from `main`: `git checkout main && git pull && git checkout -b feat/github-native-phase-1`.
2. Add deps: `:joken` for JWT (RS256 support is built-in via `:jose` which Joken pulls in), `:bandit` for the HTTP server. Justify any other addition in the PR description.
3. Build `Sykli.GitHub.App` first, with the behaviour + Real + Fake split. Tests cover JWT shape, installation token caching, expiry handling.
4. Build `Sykli.GitHub.Webhook.Signature` and `Sykli.GitHub.Webhook.Deliveries` (LRU). Pure functions, easy to test.
5. Build `Sykli.GitHub.Webhook.Receiver` (Plug pipeline). Tests use `Plug.Test.conn/3` against the pipeline directly — no live HTTP server in unit tests.
6. Build `Sykli.GitHub.Checks` against a localhost stub server (one `@tag :integration` test, otherwise behaviour-mocked).
7. Build `Sykli.Mesh.Roles`. Single-node-per-role acquisition via the existing mesh transport. Tests verify acquire/release/holder semantics with two simulated peers.
8. Wire the Receiver under `Sykli.Application`'s supervision tree, conditional on holding `:webhook_receiver`. Use `Bandit.start_link/1` only when the role is held; release the port on role transfer.
9. Add config scaffolding under `core/config/dev.exs` and `core/config/prod.exs` for the four env vars. `core/config/test.exs` uses the `Fake` impls and stub credentials.
10. Write `docs/github-native.md`.
11. Run the full pre-commit gate: `cd core && mix format && mix test && mix credo && mix escript.build`. Then `test/blackbox/run.sh` from the repo root — must still pass cleanly.
12. Commit in logical chunks:
    - `feat(github): add Sykli.GitHub.App with JWT and installation tokens`
    - `feat(github): add webhook signature verification and delivery LRU`
    - `feat(github): add Sykli.GitHub.Webhook.Receiver Plug pipeline`
    - `feat(github): add Sykli.GitHub.Checks API client (suite + run lifecycle)`
    - `feat(mesh): add Sykli.Mesh.Roles with single-node-per-role placement`
    - `feat(github): wire receiver into supervision tree under :webhook_receiver role`
    - `docs: add docs/github-native.md walkthrough`
13. Push and open PR targeting `main`. Title: **`feat(github): Phase 1 — GitHub-Native foundation (ADR-021)`**. Body: 1-line summary + bulleted scope + a screenshot of `gh api /repos/<test>/check-suites` showing the `queued` suite created from a real webhook delivery.

**Acceptance criteria:**

- [ ] `mix test`, `mix credo` (NoWallClock satisfied), `mix format` clean.
- [ ] `mix escript.build` produces a binary; `./core/sykli --help` works (no regression to v0.6 visual reset).
- [ ] `test/blackbox/run.sh` passes all cases.
- [ ] An `@tag :integration` test demonstrates the loop end-to-end against a localhost stub: signed webhook arrives, signature verified, installation token issued (mocked), check suite created. The same test asserts that an unsigned (or wrong-signature) webhook is rejected with no body logged.
- [ ] `Sykli.SCM.GitHub` (the fallback Commit Status path) is **untouched** and its existing tests still pass unchanged.
- [ ] No new GenServer "owns the GitHub state" globally. Token cache is ETS or `:persistent_term`. Delivery LRU is ETS. Both ephemeral, both restartable.
- [ ] No new top-level deps beyond Joken + Bandit (and their transitive deps). Justify any addition in the PR body.
- [ ] The receiver listens only on the node holding `:webhook_receiver`. On every other node, the supervisor child is a no-op. Verified by an integration test.
- [ ] `docs/github-native.md` walks a user from zero to "queued check on a real PR" without referencing internal implementation modules.

**Anti-patterns — do not do these:**

- ✗ Don't build a Phoenix application. The receiver is a Plug pipeline + Bandit listener; that is the whole HTTP stack.
- ✗ Don't add a database. Phase 1 state is ephemeral: cached installation tokens, delivery ID LRU. Both ETS.
- ✗ Don't introduce a new "service framework" abstraction. Reuse `Sykli.Application` supervision and `Sykli.Mesh.Roles`.
- ✗ Don't silently swallow GitHub API errors. Use `Sykli.Error` structs with codes (`github.app.unauthorized`, `github.checks.write_failed`, `github.webhook.bad_signature`), propagate, log via `Logger.warning` with structured metadata.
- ✗ Don't auto-amend commits. Don't `--no-verify`. Don't bypass signing.
- ✗ Don't add comments explaining what code does. WHY only, when non-obvious. No multi-paragraph docstrings.
- ✗ Don't add a feature flag toggling "old vs new GitHub integration." The fallback Commit Status path lives on its own path; this is purely additive.
- ✗ Don't dispatch a real pipeline run. **That is Phase 2.** If you find yourself touching `Sykli.Executor`, you have left scope.

**Things to ask if you can:**

- JWT library preference (Joken vs raw :jose)? Default: **Joken**.
- HTTP server preference (Bandit vs Plug.Cowboy)? Default: **Bandit**.
- ETS vs `:persistent_term` for installation token cache? Default: **ETS** (read-heavy, modest churn, easier to inspect).
- Webhook delivery LRU bound? Default: **10,000 entries, 24h TTL**.
- Default port for `SYKLI_GITHUB_RECEIVER_PORT`? Default: **8617**.

If you cannot ask, use the defaults.

---

**End of Phase 1 prompt.** When this PR is merged, kick off Phase 2 with a separate prompt that picks up where this leaves off: webhook → mesh placement → executor → check run lifecycle.
