# Sykli Workbench (`sykli gui`)

A local-first execution control room for one repo. One screen answers: what
was declared (the contract), what ran (the graph), who or what moved the
work forward (humans, agents, daemons, CI), what failed and why, what
evidence exists, and who is allowed to unblock the next step (gates).

```
sykli gui [--port N] [--no-open] [--demo] [--json]   # shipped binary
mix sykli.gui                                         # development convenience
```

Binds `127.0.0.1` only. No auth, no cloud, no billing, no org admin, no
analytics. This is not the commercial fleet-dashboard surface reserved in
`docs/strategy-2026.md` — it is the free, single-repo, single-user tool.

## Architecture

Bandit + Plug (`Sykli.Gui.Router`), the same stack as the webhook receiver
and coordinator — deliberately not Phoenix. The SPA (hand-written HTML/CSS/
JS in `core/priv/gui/`) is **embedded at compile time** via
`Sykli.Gui.Assets`, because `priv/` paths are not readable from inside an
escript archive; the same bytes serve from `mix`, the escript, and Burrito
releases. `@external_resource` keeps embedded copies in sync — editing an
SPA file recompiles the module.

### The provider seam

All data flows through one behaviour, so demo and real providers are
interchangeable and the web layer never scrapes CLI text:

```elixir
Sykli.Gui.Provider          # behaviour: state/1, run/1, approve_gate/2, reject_gate/3
Sykli.Gui.Provider.Artifact # real local data (default for `sykli gui`)
Sykli.Gui.Provider.Demo     # hardcoded realistic state (`sykli gui --demo`)
```

`sykli gui` selects the artifact provider unless `--demo` is passed; tests
and embedders can override with `config :sykli, :gui_provider, <module>`.

The artifact provider reads **artifacts only** — it never executes repo
code. Sources: repo identity from git; the contract from `sykli.lock`
(preferred; carries schema version, gate and review counts) or
`.sykli/context.json` (structure only); runs and evidence from
`.sykli/runs/` manifests; work items from `Sykli.Work.Store`; gates from
`Sykli.Gate.Store`. Gate approve/reject **write through** `Gate.Store`
with a `member:`-qualified `decided_by`, so a Workbench decision is the
same artifact `sykli gate approve` produces. A repo that has never run
`sykli lock` or `sykli context` shows no contract until one of those
runs — `GET /api/state` must not trigger an SDK emit. Team-mode members
and agent tool-call history stay empty until their local artifacts exist
(the member list is the local git identity for now).

### API

`GET /api/state` returns the full state document (camelCase) inside the
shared JSON envelope (`Sykli.CLI.JsonResponse` — same shape agents parse
everywhere else). `POST /api/gates/:id/approve` / `.../reject` take
`{"actor": ...}` (+ `"reason"`). `GET /api/runs/:id` returns one run.

### v5 fields

The state model carries the actor/mandate/audit story end to end: graph
nodes have `mandateOutcome` (`kept` / `violated` / `unverified` /
`unsupported`), agent/daemon members carry their declared `mandate`
(scope, budgets, network — canonical shape `capabilities.network`) beside
the ALLOWED / NOT ALLOWED permission chips, and evidence entries carry
`auditVerdict` and a mandate summary. The artifact provider populates all
of these from real sources: mandate outcomes from run manifests (persisted
by mandate enforcement), declared actors/mandates from the contract, and
`auditVerdict` computed per state read through `Sykli.Services.Audit` —
the same read-time judgment `sykli audit` prints, never persisted.

## Design

Nordic Bauhaus control room, per the design handoff: strict grid, calm,
static; color is state only (green/red/amber/cyan/grey), geometry is
identity (task=square, gate=diamond, human=open circle, agent=filled
circle, daemon=filled rect, CI=outlined rect); no border-radius, no
shadows, no chat UI. Team members are execution participants, not SaaS
users — an agent must never look like it can approve a human gate.
