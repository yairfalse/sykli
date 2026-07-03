# Guardrails Conformance

Tree anchor: exact commit OID until Toimija consistency tokens are wired.
Gate environment: `ERL_COMPILER_OPTIONS=[deterministic]`; CI pins the same BEAM versions as `.tool-versions`.
Gate alias commands: `deps.get --check-locked`, `deps.unlock --check-unused`,
`format --check-formatted`, `credo --strict`,
`compile --warnings-as-errors --force`, `deps.audit`, `test --seed 0`.

## Conformance Table

| ID | Status | Evidence |
| --- | --- | --- |
| B-0.1 | met | `.tool-versions` pins OTP and Elixir. |
| B-0.2 | met | `core/mix.lock` committed; `mix gate` checks locked and unused deps. |
| B-0.3 | gap | `mix_audit` currently fetches advisory data; pinned advisory snapshot not implemented. Issue: pending guardrails rollout ticket. |
| B-0.4 | met | Gate env declares `ERL_COMPILER_OPTIONS=[deterministic]`. |
| B-0.5 | gap | Dialyzer/PLT cache not installed. Issue: pending guardrails rollout ticket. |
| B-0.6 | met | Gate env is declared here and in CI. |
| B-0.7 | met | Verdicts anchor to commit OID until Toimija token support lands. |
| B-S.1 | met | `mix gate` runs formatter check; `core/.formatter.exs` committed. |
| B-S.2 | met | `mix gate` runs `mix credo --strict`; `core/.credo.exs` committed. |
| B-S.3 | met | `mix gate` runs compiler warnings as errors. |
| B-S.4 | gap | Dialyzer is not installed; repo declaration is gradual. Issue: pending guardrails rollout ticket. |
| B-S.5 | partial | Sobelow n-a: no Phoenix surface. Credo has deterministic custom lint; atom/apply hard lints not yet added. Issue: pending guardrails rollout ticket. |
| B-S.6 | gap | `mix hex.audit` is not available in the current Hex install. License policy is also a named gap. Issue: pending guardrails rollout ticket. |
| B-S.7 | gap | `mix deps.audit` gates, but not against a pinned advisory snapshot yet. Issue: pending guardrails rollout ticket. |
| B-D.1 | met | ExUnit is the core runner; black-box/conformance remain separate repository suites. |
| B-D.2 | met | Gate runs `mix test --seed 0`; CI has scheduled fresh-seed soak. |
| B-D.3 | gap | Async isolation audit not completed. Issue: pending guardrails rollout ticket. |
| B-D.4 | partial | Contract hash tests cover canonical JSON; full snapshot/digest audit pending. Issue: pending guardrails rollout ticket. |
| B-D.5 | partial | Simulator RNG is seeded; full comparison-output audit pending. Issue: pending guardrails rollout ticket. |
| B-D.6 | partial | Timeout tests exist; full sleep/assert_receive audit pending. Issue: pending guardrails rollout ticket. |
| B-D.7 | partial | Cross-SDK conformance fixtures exist; Mox behaviour coverage not adopted. Issue: pending guardrails rollout ticket. |
| B-D.8 | partial | Integration tags exist; skip-tag issue-link enforcement pending. Issue: pending guardrails rollout ticket. |
| B-G.1 | partial | StreamData is installed; counterexample promotion rule documented in `CONTRIBUTING.md`. |
| B-G.2 | gap | PropCheck state-machine suites not installed. Issue: pending guardrails rollout ticket. |
| B-G.3 | gap | Concuerror scheduled lane not installed. Issue: pending guardrails rollout ticket. |
| B-G.4 | met | No hot BEAM binary parser fuzz lane declared. |
| B-G.5 | gap | Muzak not running; coverage ratchet is the compensating control to add. Issue: pending guardrails rollout ticket. |
| B-G.6 | n-a | No deterministic performance gate declared. |
| B-C.1 | gap | Coverage ratchet against main not implemented. Issue: pending guardrails rollout ticket. |
| B-E.1 | met | `.github/CODEOWNERS` protects guardrail-sensitive paths. |
| B-E.2 | partial | sykli contract --diff classifies weakening changes; CI gating pending. |
| B-E.3 | gap | Scope conformance check not implemented. Issue: pending guardrails rollout ticket. |
| B-E.4 | gap | Diff budget check not implemented. Issue: pending guardrails rollout ticket. |
| B-R.1 | met | `mix gate` is committed in `core/mix.exs`. |
| B-R.2 | gap | JSONL verdict record not implemented. Issue: pending guardrails rollout ticket. |
| B-R.3 | met | `scripts/check-guardrails-gate.sh` guards declaration/alias drift. |
| B-R.4 | partial | No gate retry plugin found; quarantine inventory not implemented. Issue: pending guardrails rollout ticket. |
| B-R.5 | gap | Bypass inventory not implemented. Issue: pending guardrails rollout ticket. |

## Not-Covered Inventory

- Gradual typing: Dialyzer/Dialyxir and PLT caching are not installed.
- Pinned advisory database: `mix_audit` is present, but advisory input pinning is not.
- License policy: no committed `mix.lock` license allowlist task exists.
- Stateful/concurrency generation: PropCheck, Concuerror, and Muzak lanes are not installed.
- Diff guardrails: test-weakening, scope, diff budget, bypass, and quarantine inventories are not installed.
