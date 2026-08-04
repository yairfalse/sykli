# Contributing to Sykli

Thanks for considering a contribution. This document covers the practical
path from clone to merged PR. For what Sykli *is*, read the
[README](README.md); for installation, [GETTING_STARTED.md](GETTING_STARTED.md).

## Project layout

| Path | What lives there |
|---|---|
| `core/` | The Elixir/BEAM engine — parsing, validation, execution, evidence |
| `sdk/{go,rust,typescript,elixir,python}/` | The five SDKs. Each is an independent project |
| `schemas/` | `sykli-pipeline.schema.json` (the canonical wire contract) + `vocabulary.json` |
| `tests/conformance/` | Cross-SDK conformance: all SDKs must emit byte-identical JSON |
| `test/blackbox/` | Black-box suite against the built binary |
| `eval/` | Oracle ground-truth cases + AI-agent eval harness |
| `docs/` | Design docs. Several are normative — they constrain changes |

## Building and testing

The engine requires Elixir 1.14+:

```bash
cd core
mix deps.get
mix test                  # unit tests (no Docker needed — runs against a fake runtime)
mix escript.build         # dev binary → core/sykli
mix gate                  # deterministic guardrail gate: locked deps, static checks, audits, seed 0 tests
mix verify                # the full local CI pyramid: format, test, credo, build, blackbox, conformance
```

`mix verify` (or `make verify` from the repo root) runs exactly what CI runs.
If it's green locally, CI should be green.

Useful narrower loops:

```bash
mix test test/sykli/executor_test.exs:42      # one test
mix test.docker                               # container-runtime tests (needs Docker)
tests/conformance/run.sh --sdk go             # one SDK's conformance
test/blackbox/run.sh --filter=POS             # filtered black-box cases
```

Before every commit: `mix format && mix test && mix escript.build`.

Property failures from StreamData must be promoted into an explicit example
test before the fix merges; the shrunken input is the regression.

## The rules that will catch you (they're all tested)

These aren't style preferences — the test suite enforces them, so knowing
them up front saves a CI round-trip:

1. **The schema is the contract.** `schemas/sykli-pipeline.schema.json` is
   strict (`additionalProperties: false`). SDK output must validate against
   it; the engine accepting something is *not* the bar. Changing a task
   schema field means updating: the schema, all five SDK emitters, the
   engine parse + validate paths, and at least one conformance case with
   per-SDK fixtures. See `docs/sdk-schema.md`.
2. **Shared vocabulary is generated, not copied by hand.**
   `schemas/vocabulary.json` is canonical; `scripts/gen-vocab.py --check`
   fails CI on drift across engine, schema, SDKs, and fixtures.
3. **Runtime isolation.** No module outside `core/lib/sykli/runtime/` may
   name a concrete runtime (`Docker`, `Podman`, `Shell`, `Fake`). A test
   greps the tree and fails on offenders. Selection goes through
   `Sykli.Runtime.Resolver`.
4. **No wall-clock in pure transforms.** A custom Credo check
   (`NoWallClock`) bans `DateTime.utc_now` & friends in contract/
   output-shaping modules. Deterministic output is a feature.
5. **CLI output rules are binding.** Glyph language, one accent color,
   banned vocabulary in passing output — all tested. Read the
   "CLI output rules" section of `CLAUDE.md` before touching anything that
   prints.
6. **Structured errors only.** New externally visible error codes go in
   `docs/error-codes.md` with a stability tier before they appear in JSON,
   MCP, or occurrences. All `--json` output flows through
   `Sykli.CLI.JsonResponse` — never hand-roll an envelope.
7. **Dual-surface definition of done.** Every feature must serve both the
   human CLI output and the agent-readable JSON/MCP surface. `docs/done.md`
   is part of review, not aspiration.

## Good first contributions

- **A new review primitive** — deterministic checks dispatched from
  `kind: "review"` nodes (see `docs/review-primitives.md` and
  `core/lib/sykli/review_primitive.ex`). Self-contained, well-bounded,
  and immediately useful.
- **SDK parity items** — the conformance suite makes "did I get it right?"
  a script, not a judgment call.
- **Conformance cases** — new positive cases in `tests/conformance/cases/`
  or negative fixtures in `tests/conformance/schema-invalid/`.
- **A sixth SDK** — ambitious but fully specified: emit JSON that passes
  the conformance suite. Open a discussion first so we can coordinate.

Issues labeled `good-first-issue` are kept genuinely scoped.

## Pull requests

- Branch from `main`: `feature/<short-description>` (or `fix/`, `docs/`)
- Commit style: `type(scope): subject` — `feat(sdk-go): ...`,
  `fix(executor): ...`, `docs: ...`
- Keep PRs single-purpose and small; a green `mix verify` before pushing
  is the strongest review accelerant there is
- Update `CHANGELOG.md` under `[Unreleased]` for user-visible changes
- New docs in `docs/` must be allowlisted in `.gitignore`
  (`!docs/<name>.md`) or they silently won't commit

## Conduct

We follow the [Code of Conduct](CODE_OF_CONDUCT.md). Be kind; assume good
faith; critique contracts, not people.

## Questions

Open a [GitHub Discussion](https://github.com/false-systems/sykli-elixir/discussions)
for design questions and ideas; reserve issues for bugs and scoped work.
