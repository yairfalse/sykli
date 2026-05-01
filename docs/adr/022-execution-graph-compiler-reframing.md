# ADR-022: Reframing sykli as an Execution Graph Compiler

**Status:** Accepted
**Date:** 2026-05-01
**Supersedes:** ADR-020 (positioning section only; visual direction preserved)

---

## Context

ADR-020 positioned sykli as *"local-first CI for the next generation of software developers."* That framing was useful early:

- CI is a familiar entry point — buyers and contributors recognize the category instantly.
- It grounded the product in a concrete use case with known primitives (tasks, dependencies, inputs, outputs).
- It deferred the question of *what this really is* until the execution model was proven.

But the framing has started to constrain the system conceptually:

- It reduces sykli to build/test/deploy workflows in the imagination of new users.
- It hides the generality of the execution model — the same primitives work for non-CI tasks.
- It blocks modeling reviews, security analysis, and agent-driven reasoning as first-class graph nodes.
- It positions sykli as a competitor in a crowded category instead of as a primitive layer below it.

The Kubernetes and Terraform precedents are instructive:

- Kubernetes started as "container orchestration" and would have been boxed in had it stayed there. It is now described as a control plane.
- Terraform started as "provisioning" and would have been boxed in had it stayed there. It is now described as an infrastructure graph engine.

In both cases, the framing change came after the primitives proved more general than the original use case. sykli has the same shape.

---

## Decision

> **sykli is a compiler for programmable execution graphs.**

CI is a primary but non-exclusive use case. The lead positioning sentence — in README, marketing surfaces, and the elevator pitch — is now:

> **Execution graphs as code.**

---

## What changes

- **Primary positioning is no longer "CI."** README leads with execution graphs; CI is one section, not the headline.
- **"Execution graph" becomes a first-class concept** in docs and SDK surface.
- **AI-readability is a consequence, not the lead claim.** Structured occurrences are evidence of the underlying graph model, not the headline.
- **Tasks include three kinds of work**, not just build/test/deploy:
  - **Computation** — build, test, package
  - **Validation** — lint, type-check, security analysis
  - **Reasoning** — code review, design review, observability regression analysis
- **Agents are executors inside the graph, not magical reviewers.** Claude, Codex, local models, deterministic linters all fulfill the same node contract. A review primitive is a node with constrained inputs, expected outputs, and explicit rules — the executor is interchangeable.

---

## What does not change

ADR-020's **local-first commitment is preserved in full.** Specifically:

- The user's hardware is the execution authority.
- sykli ships software, not a service. No hosted SaaS, no multi-tenant control plane.
- Network features are opt-in, never required.
- Determinism and reproducibility are first-class.

ADR-020's **visual direction (Nordic Minimal, glyph language, accent color, output rules) is preserved in full.** The CLI aesthetic and the testable rules under "CLI output rules (ADR-020)" remain the canonical reference. This ADR supersedes only the *positioning* section of ADR-020, not the *visual direction* section.

---

## What this enables

The reframing makes legitimate first-class concepts of workflows that were already technically possible:

- **PR reviews as graph nodes** — review primitives (`review/security`, `review/api-breakage`, `review/observability-regression`, `review/test-coverage-gap`, `review/architecture-boundary`) with structured outputs.
- **Release validation** — multi-stage gates with typed evidence, not bash scripts in `.github/workflows/`.
- **Infrastructure validation** — drift detection, policy compliance, configuration checks as graph nodes.
- **Agentic workflows** — multiple agents fulfilling the same primitive, with disagreement surfaced as graph state rather than hidden in chat logs.

---

## Consequences

- **`README.md`** — rewritten around the new positioning. The previous "What is Sykli?" / "Three things that make Sykli different" structure is replaced with "Execution graphs as code" + "sykli is not CI" + "Why YAML is not enough" + "Agentic review as code." (Landed in the same PR as this ADR.)
- **`CLAUDE.md`** — the "What is Sykli?" section needs updating to surface the new thesis sentence. Follow-up PR.
- **ADR-021** — unchanged. The GitHub-native receiver remains the v0.7 integration mechanism. The framing of *what* it integrates with is broader (execution graphs, not just CI) but the architecture is identical.
- **Marketing surfaces** — the elevator pitch becomes *"sykli is a compiler for programmable execution graphs."* CI is a section, not the lead.
- **Existing documents that quote ADR-020's old positioning line** — the visual reset PR description, the Codex Phase 1 / 2 / 2.5 prompts — are not retroactively edited. They were correct at the time of writing. New documents adopt the new framing.

---

## Why this matters

The execution-graph primitives sykli has built — typed task definitions across five languages, content-addressed cache, capability-based placement, deterministic replay, FALSE Protocol structured events, SLSA attestations — generalize beyond CI. Continuing to frame the project as *"CI but better"* would lock that generality out of the conversation. The reframing is not aspirational; the primitives are already general. The framing has been narrower than the implementation.

---

## References

- **ADR-020** — Positioning, Audience, and Visual Direction. Positioning section superseded by this ADR; visual direction preserved.
- **ADR-021** — GitHub-Native Integration via Webhook + Mesh Receiver. Unchanged.
- **ADR-001** — Meta-design ("local first, remote when you have to"). Reinforced.
- **ADR-006** — Local/Remote Architecture. Reinforced.
