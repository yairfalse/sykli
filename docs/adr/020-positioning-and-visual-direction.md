# ADR-020: Positioning, Audience, and Visual Direction

**Status:** Proposed
> Positioning section superseded by ADR-022 (2026-05-01). Visual direction remains canonical.

**Date:** 2026-04-27

---

## Context

Sykli's substance is strong — runtime decoupling, FALSE Protocol occurrences, attestations, eval harness, MCP server, AI-readable failure analysis. But the project has never written down *who it is for* or *how it should look*. The README is a list of features, the CLI output is a kitchen sink of every color in the default palette, and the marketing claims ("CI as real code", "AI reads the results", "supply chain signed") are three claims fighting for the same headline.

Without a canonical positioning, every decision drifts: do we add an enterprise dashboard? Do we ship a SaaS? Do we make the CLI cute or sober? Each new contributor (human or agent) re-litigates the same questions.

This ADR fixes positioning, audience, and visual direction in one place so future decisions can be measured against it.

---

## Decision

### Thesis

> **Sykli is local-first CI for the next generation of software developers.**

This is the canonical one-sentence statement. It is the headline of the README, the elevator pitch, and the test against which features are accepted or rejected.

### What "local-first" commits us to

Local-first is a category term (Ink & Switch et al.), not just an adjective. Adopting it commits us to:

- **The user's hardware is the execution authority.** Sykli runs on the developer's laptop, their mesh, their self-hosted runners, their VPS. Never on hardware Sykli (the project) owns or operates.
- **The project ships software, not a service.** No hosted dashboard. No multi-tenant control plane. No SaaS billing. No on-call rotation.
- **Network is opt-in.** A developer with no internet, no GitHub, and no S3 still gets a working CI tool. Cloud features (S3 cache, GitHub status, mesh peering across networks) are additive, never required.
- **Determinism and reproducibility are first-class.** Local-first software in a multi-machine world only works if runs are replayable byte-for-byte. This reinforces the existing direction in ADR-010 and the simulator scaffolding.

### Audience

> **Developers who chose Bun over npm, mise over nvm, Linear over Jira, Raycast over Spotlight, Tailscale over OpenVPN, Vercel/Fly over raw AWS — and who code daily with AI agents.**

This audience:

- Has taste and pays for tools that respect it.
- Believes their tools should be fast, beautiful, and opinionated.
- Has never accepted that "real CI" requires YAML and a vendor dashboard.
- Treats AI assistants (Claude Code, Cursor, Copilot) as a daily collaborator, not a novelty.
- Cares about supply chain provenance — signed builds, verifiable attestations.
- Wants to debug locally, not by re-running CI to read logs.

### What this rules in

- Polished, restrained CLI experience modeled on Linear/Vercel/Raycast.
- AI-readability as a headline feature (`sykli fix`, `sykli mcp`, the FALSE Protocol).
- Mesh as peer-to-peer infrastructure for *one user's* nodes (laptop + office + VPS), not a hosted service.
- GitHub-native integration via the user's own infrastructure (see ADR-021).
- Single-binary install, `brew install sykli`, `mise use sykli`.

### What this rules out

- ❌ Hosted SaaS where users submit jobs to Sykli-owned infrastructure.
- ❌ Multi-tenant control plane.
- ❌ Enterprise CI vendor positioning (do not compete with Jenkins/CircleCI on their turf).
- ❌ "AI-native CI" as the lead claim — it's vibe-marketing. Local-first is positioning; AI-readability is evidence.
- ❌ Charm-style playful aesthetic. Bun-style bro/hype aesthetic. Either fights the brand.
- ❌ YAML configuration. Ever.

---

## Visual Direction

### Aesthetic: Nordic Minimal

Reference set: **Linear**, **Vercel CLI**, **Raycast**. Common DNA: near-black backgrounds, near-white text, surgical use of whitespace, *one* cold accent color, almost-invisible micro-interactions, restraint as the dominant move.

Sykli adopts this aesthetic verbatim. It is consistent with the audience, with local-first as a sober commitment, and with the supply-chain-as-craft brand.

### Accent color

**One** accent: cold cyan-teal (approximately `#7DD3D8`). Used **only** for:

- The success glyph (`●`)
- The running-state spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`)
- The wordmark in marketing surfaces

Never for warnings, errors, dim text, separators, or decorative use. The accent is reserved.

Errors use red (`✕`). Warnings use yellow. Cache hits and skipped tasks use no color at all (they should feel free, not negative).

### Glyph language

Status is carried by glyph, not color. A user in a colorblind-friendly terminal, or a screenshot-of-a-screenshot, must still parse the run.

| Glyph | Meaning |
|-------|---------|
| `●`   | Passed (cyan-teal) |
| `○`   | Cache hit (no color) |
| `✕`   | Failed (red) |
| `─`   | Blocked / skipped (no color) |
| `⠋`   | Running (cyan-teal, animated) |

### Output rules

These are commitments, not suggestions. Code-level enforcement lives in the renderer module (see Consequences).

1. **One summary per run.** Not two, not three. Today's output emits up to three; that is a bug.
2. **No internal vocabulary.** "Level", "1L", "(first run)", "Target: local (docker: Docker version 28.5.1, build e180ab8)" — all banned. The user's mental model is *tasks* and *runs*. The renderer speaks that vocabulary, nothing else.
3. **Right-aligned timing column.** Time-to-glance for "what was slow" should be one eye movement.
4. **Streamed task stdout is hidden by default.** Show on failure, or with `--stream`. Today's interleaved dim-grey output is the worst of both worlds.
5. **Animation lives in a single redraw region.** Cursor save/restore, dirty-row tracking. No new lines emitted until a task transitions to terminal state.
6. **Failure is the highest-stakes surface.** When something fails, the renderer collapses success noise, draws a horizontal rule under the failed task, shows the offending output inline, and points the user at `sykli fix` in a single line.
7. **`sykli fix` is the screenshot moment.** Its renderer is a separate module with its own layout. It shows: what broke, where it changed (git provenance), the proposed fix, and a one-line causality statement.

### Reference frame: passing parallel run

```
sykli · parallel_tasks.exs                         local · 0.5.3

  ⠋  task_a    echo a
  ⠋  task_b    echo b

  ●  task_a    echo a                                  108ms
  ●  task_b    echo b                                  112ms

  ─  2 passed                                          111ms
```

### Reference frame: failure

```
sykli · build.exs                                  local · 0.5.3

  ●  test         go test ./...                       1.8s
  ✕  build        go build ./cmd/app                  912ms
  ─  lint         golangci-lint                       skipped (blocked)

  ─  1 failed · 1 passed · 1 blocked                  2.7s

  ✕  build  ─────────────────────────────────────────────

      ./cmd/app/main.go:42:13: undefined: ResolveOpts

      Run  sykli fix  for AI-readable analysis.
```

---

## Consequences

### README

The current 220-line README is rewritten around the thesis. Hero is three lines + one code sample + one terminal frame in the new visual style. The MCP server and `sykli fix` are surfaced above the fold — they are the differentiators, not side features.

### CLI

A new `Sykli.CLI.Renderer` module owns frame composition (header, task rows, summary) as pure functions returning IO-lists. A new `Sykli.CLI.Live` module owns the redraw region. The current line-emit-per-event renderer in `cli.ex` is replaced. `sykli fix` gets its own renderer. Estimated 2 weeks for a v0.6 visual reset across the most-watched commands.

### Marketing surfaces

Wordmark: lowercase `sykli`. No all-caps. No custom monogram in v0.6 — defer until brand work has budget.

Badges that don't resolve to real published packages are removed from the README. If `sykli` is published to crates.io / hex.pm later, the badges return.

### Architecture

This ADR has architectural force, not just aesthetic. The local-first commitment is now load-bearing for every future ADR. Specifically:

- ADR-021 (GitHub-native integration) is constrained: the receiver must run on the user's mesh, never on Sykli-owned infrastructure.
- ADR-006 (cluster peers) and ADR-001 (local first, remote when you have to) are reinforced and cited as load-bearing.
- ADR-012's "Cloud Mesh" Phase 2 hint is constrained: cloud nodes join the user's cluster as peers; they are not a centralized dispatcher.

### Decisions deferred

These are intentionally *not* decided here, to keep this ADR scoped:

- The exact hex value of the accent color (`#7DD3D8` is a target; designer can tune).
- The wordmark typeface for marketing surfaces (CLI uses the terminal's monospace).
- Whether `sykli init` becomes a TUI flow or stays as a one-shot scaffolder.
- Light-terminal palette (the spec above assumes dark; light mode is a follow-on).

---

## References

- **Local-first software** — Kleppmann, Wiggins, van Hardenberg, McGranaghan. <https://www.inkandswitch.com/local-first/>
- **ADR-001** — Meta-design ("local first, remote when you have to")
- **ADR-006** — Local/Remote Architecture (cluster peers)
- **ADR-010** — Reproducible Builds (determinism foundation)
- **ADR-012** — BEAM Superpowers (Cloud Mesh Phase 2 hint)
- **ADR-021** — GitHub-Native Integration via Webhook + Mesh Receiver (downstream of this ADR)
