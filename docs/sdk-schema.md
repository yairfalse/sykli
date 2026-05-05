# Sykli SDK Pipeline Schema

## Status

This document describes the **current** Sykli pipeline JSON contract. It is grounded in:

- The engine parser (`core/lib/sykli/graph.ex`) and per-field modules (`core/lib/sykli/graph/task/*.ex`).
- Engine validation (`core/lib/sykli/validate.ex`).
- The five SDK emitters (`sdk/{go,rust,typescript,elixir,python}/`).
- The 21 conformance fixtures (`tests/conformance/cases/*.json`).

It is **not** a future design document. The agent-native semantic fields proposed in `docs/sdk-audit.md` §10 (Phase 3) — `task_type`, structured `inputs`, structured `outputs`, `success_criteria`, `side_effects`, `expected` — are intentionally out of scope.

The companion machine-readable schema is `schemas/sykli-pipeline.schema.json` (JSON Schema draft 2020-12).
Conformance case fixtures are validated against it by `scripts/validate-conformance-schema.py`, which runs at the start of `tests/conformance/run.sh`.

## Contract boundary

The canonical contract is the JSON emitted by SDKs and consumed by the engine. The schema in this repository describes the **canonical SDK-emitted JSON shape** and is intentionally strict (`additionalProperties: false`).

The engine is currently **more permissive** than the schema in three known ways:

1. **Unknown top-level and per-task keys are silently ignored** by `graph.ex:368-414`. The schema rejects them.
2. **`condition` is accepted as an alias for `when`** (`graph.ex:382`: `map["when"] || map["condition"]`). The schema accepts both individually but forbids setting both at once.
3. **`outputs` may be a list** that the engine normalizes to `output_0, output_1, ...` (`graph.ex:500-514`). All five SDKs emit the map form; the schema accepts only the map form.

**The JSON Schema validates canonical SDK output. It does not validate every shape the engine can parse.** A payload that validates against the schema is guaranteed to parse and validate cleanly through the engine. A payload the engine accepts may not validate against the schema if it relies on the permissive paths above. SDK-emitted output should always be schema-conformant.

## Top-level object

```jsonc
{
  "version": "1" | "2",
  "tasks":   [ ... task objects ... ],
  "resources": { ... }   // optional
}
```

### `version`

- **Type:** string enum `"1"` | `"2"`.
- **Required by canonical schema; ignored by current engine.**
- **Meaning:** pipeline wire-format/schema version. It is not an execution capability selector and not an SDK, engine, runtime, or JSON Schema draft version.
- `"1"` is the baseline task graph format.
- `"2"` is the resource-aware format: resources, mounts, caches, containers, and related execution-environment metadata.
- SDKs auto-detect: `"2"` if any task has `container` set, or any task has non-empty `mounts`, or the pipeline has any directory or cache resources; `"1"` otherwise.
- **Current behavior:** advisory / permissive. The engine parser does not branch on this value (no `Map.get(map, "version", _)` anywhere in `graph.ex`).
- **Intended future behavior:** the engine should accept known supported versions and reject unknown future versions unless an explicit compatibility mode exists. It should never silently reinterpret a newer document as an older version.

### `tasks`

- **Type:** array of task objects.
- **Required.**
- May be empty. The engine accepts `tasks: []` without error; downstream validation produces no work.

### `resources`

- **Type:** object mapping resource id (e.g., `src:.`, `cache:go-mod`) to a resource definition.
- **Optional.** Emitted only when v2 features are present.
- Each value has the shape `{ "type": "directory" | "cache", "path"?: string, "globs"?: string[], "name"?: string }`.
- `path` is required for `type=directory`. `name` is required for `type=cache`.

## Task object

Tasks have a strict known-field set. The schema rejects unknown properties. The engine ignores them.

The full canonical field list, with stability labels:

| JSON key | Stability | Required? | Notes |
|---|---|---|---|
| `name` | stable | yes | unique, non-empty |
| `kind` | experimental (non-Go SDKs) | no | `"task"` (default) or `"review"`; only Go emits `"review"` |
| `command` | stable | conditional | required unless `gate` is set or `kind == "review"` |
| `container` | stable | no | triggers v2 |
| `workdir` | stable | no | |
| `env` | stable | no | object of string values |
| `inputs` | stable | no | array of glob patterns for cache invalidation |
| `outputs` | stable | no | object of `name → path` |
| `depends_on` | stable | no | array of task names; engine deduplicates |
| `task_inputs` | stable | no | structured artifact dependencies |
| `when` | stable | no | conditional expression (string) |
| `condition` | **deprecated alias** for `when` | no | engine accepts both; SDKs should emit `when` |
| `secrets` | stable | no | array of secret names (env-resolved) |
| `secret_refs` | stable | no | typed references with explicit source |
| `matrix` | stable | no | dimension-name → values; engine expands Cartesian product |
| `services` | stable | no | array of `{image, name}` |
| `mounts` | stable | no | array of `{resource, path, type}` |
| `retry` | stable | no | non-negative integer |
| `timeout` | stable | no | positive integer (seconds) |
| `k8s` | stable (4-field shape) | no | `{memory, cpu, gpu, raw}` only |
| `requires` | stable | no | array of mesh node labels |
| `provides` | stable | no | array of `{name, value?}` |
| `needs` | stable | no | array of capability names |
| `semantic` | stable | no | `{covers, intent, criticality}` |
| `ai_hooks` | stable | no | `{on_fail, select}` |
| `gate` | stable | no | `{strategy, timeout?, message?, env_var?, file_path?, webhook_url?}` |
| `verify` | reserved | no | engine-readable; no SDK currently emits |
| `oidc` | reserved | no | engine-readable; no SDK currently emits |
| `history_hint` | engine-internal / read-only | no | populated by Sykli runtime; SDKs MUST NOT emit |
| `primitive` | review-only, experimental | no | meaningful only when `kind == "review"` |
| `agent` | review-only, experimental | no | meaningful only when `kind == "review"` |
| `context` | review-only, experimental | no | meaningful only when `kind == "review"` |
| `deterministic` | review-only, experimental | no | meaningful only when `kind == "review"` |

### `name`

Unique within the pipeline, non-empty. The engine rejects empty/whitespace/non-binary names (`validate.ex:115-128`) and duplicates (`validate.ex:130-140`). SDKs panic / raise on construction with empty names.

### `kind`

`"task"` (default; SDKs do not emit `kind` in this case) or `"review"`. When `kind == "review"`, `command` is not required and the review-only fields below become meaningful. Today only the Go SDK constructs review nodes (`sdk/go/sykli.go:559-570`, `:2241-2247`); engine support is complete (`graph.ex:420-429`, `parse_review/1`). Cross-SDK parity for review nodes is a future work item — not part of this schema's scope.

### `command`

Shell command to execute. Required for regular tasks. Gates and review tasks have no command. The engine raises `missing_command` (`validate.ex:230-253`) for any non-gate, non-review task without a command. The schema does not encode this conditional rule — it would require nested `if/then/else` constructs that obscure the more common case. Treat the rule as documented engine behavior.

### `container`, `workdir`, `env`

Standard. `env` keys must be non-empty (validated by every SDK; engine accepts any).

### `inputs`

Glob patterns used for input-based caching. Files matching are hashed into the cache key.

### `outputs`

Map from output name to filesystem path. Used for artifact passing via `task_inputs`.

The engine also accepts a list-of-strings form and normalizes to `{output_0: path, output_1: path, ...}` (`graph.ex:500-514`). This is a v1 compatibility behavior; **all five SDKs emit the map form**. The canonical schema accepts only the map form.

### `depends_on`

Array of task names. Engine deduplicates (`graph.ex:381`). All referenced tasks must exist (`validate.ex:159-185`). Cycles are detected via 3-color DFS (`graph.ex:668-737`).

### `task_inputs`

Cross-task artifact dependencies. Each entry: `{from_task, output, dest}`. The engine validates (`graph.ex:766-801`) that:
- `from_task` exists in the pipeline.
- `output` is declared on the source task's `outputs`.
- The source task is in the consuming task's transitive `depends_on`.

### `when` and `condition`

Conditional expression (e.g., `branch == 'main'`). All SDKs emit `when`. The engine accepts both keys via `condition: map["when"] || map["condition"]` (`graph.ex:382`); if both are present, `when` wins. The canonical schema permits each key individually but rejects payloads with both set.

### `secrets`

V1-style array of secret names. Resolved from environment.

### `secret_refs`

V2-style typed references: `{name, source, key}` where `source ∈ {"env", "file", "vault"}`. The engine defaults `source` to `"env"` and `key` to `name` when missing (`graph.ex:449-450`). For `source=vault`, the Elixir SDK additionally enforces that `key` contains a `#` separator (e.g., `secret/data/db#password`); the engine and other SDKs accept any string.

### `matrix`

Dimension-name → values map. The engine expands the Cartesian product (`graph.ex:522-577`):

- Original task is removed; one expanded task is generated per combination.
- Expanded names: `<base>-<sorted-values-joined-by-dash>`.
- Matrix values are merged into the expanded task's `env`.
- Tasks that depended on the original name have their `depends_on` rewritten to depend on **all** expansions.

### `services`

Background containers exposed to the task by `name` as hostname. Validated parse-time (`graph.ex:455-473`): both `image` and `name` must be non-empty.

### `mounts`

Volume mounts referencing resources by id. Validated parse-time (`graph.ex:475-498`): `resource` and `path` non-empty, `type` ∈ `{"directory", "cache"}`.

### `retry`, `timeout`

Standard. SDKs omit when zero / unset.

### `k8s`

Minimal Kubernetes options:

- `memory` (string, e.g., `"4Gi"`)
- `cpu` (string, e.g., `"500m"`)
- `gpu` (integer, count of GPUs)
- `raw` (string of raw Kubernetes JSON for advanced fields)

Memory and CPU are validated by Go, Rust, Elixir, and Python SDKs against Kubernetes quantity regex; TypeScript and the engine accept any string. The TypeScript `K8sOptions` interface declares 11 additional fields (`namespace`, `nodeSelector`, `tolerations`, etc.) but `_k8sToJSON` does not serialize them; that is a TS-side type drift, not part of the contract.

### `requires`

Mesh node labels for placement, e.g., `["docker", "gpu"]`. Used by the executor at run time.

### `provides`

Capabilities this task furnishes for downstream `needs`. Each entry: `{name, value?}` where `value` is optional (a "signal" capability has no value; an "artifact-style" capability has a value the consumer can read). Cases like `02-capabilities.json`, `13-kitchen-sink.json`, `18-edge-provides-empty.json` exercise both shapes.

### `needs`

Names of required capabilities. Engine resolves: each `needs` entry creates an implicit dependency on whichever task `provides` it.

### `semantic`

Free-form metadata used by smart task selection and AI context:

- `covers` — glob patterns of files this task validates.
- `intent` — human description.
- `criticality` — `"high"`, `"medium"`, or `"low"`.

### `ai_hooks`

Behavioral hooks for AI-assisted execution:

- `on_fail` — `"analyze"`, `"retry"`, or `"skip"`.
- `select` — `"smart"`, `"always"`, or `"manual"`.

### `gate`

Approval gate. A task with a gate has no command; execution waits for approval per the strategy:

- `strategy` — required. One of `"prompt"`, `"env"`, `"file"`, `"webhook"`.
- `timeout` — engine default 3600 seconds.
- `message` — human-readable prompt.
- `env_var` — required for `strategy=env`.
- `file_path` — required for `strategy=file`.
- `webhook_url` — required for `strategy=webhook`.

### `verify`

Reserved. Engine reads it (`graph.ex:409`) but no SDK currently emits it. Likely values: `"cross_platform"`, `"always"`, `"never"`. Treat as unstable until SDK support is added.

### `oidc`

Reserved. Engine reads via `CredentialBinding.from_map` (`credential_binding.ex:35-57`) for OIDC credential binding but no SDK currently emits this field. Treat as unstable.

### `history_hint`

**Engine-internal.** Populated by Sykli at runtime from prior runs. The module docstring (`history_hint.ex:5`) states this explicitly: "populated by Sykli, not SDKs." SDKs MUST NOT emit this field. The schema includes it as `readOnly: true` for parser symmetry only.

### Review-only fields

When `kind == "review"`, the engine reads four additional fields via `parse_review/1` (`graph.ex:420-429`):

- `primitive` — review primitive identifier.
- `agent` — agent fulfilling the review.
- `context` — array of context file references.
- `deterministic` — boolean; engine default `false`.

These are meaningful only when `kind == "review"`. The schema **rejects** them on regular tasks (encoded via `if/then` in the task `allOf`): if `kind` is absent or not `"review"`, none of `primitive`, `agent`, `context`, or `deterministic` may appear. The engine itself is permissive — `parse_review/1` (`graph.ex:420-429`) is simply never entered for non-review tasks, so any review fields would be silently ignored — but the schema treats them as a likely typo. Cross-SDK support is incomplete: only Go currently emits review nodes.

## Normalization behavior

Documented engine normalizations the schema does not perform:

| Transformation | Where | Effect |
|---|---|---|
| `when` ⟂ `condition` aliasing | `graph.ex:382` | `when` wins if both present |
| `outputs` list → map | `graph.ex:500-514` | List entries become `output_0`, `output_1`, ... |
| `depends_on` dedup | `graph.ex:381` | `Enum.uniq()` removes duplicates |
| `secret_refs.source` default | `graph.ex:449` | `"env"` if missing |
| `secret_refs.key` default | `graph.ex:450` | equals `name` if missing |
| Matrix expansion | `graph.ex:522-577` | Cartesian product; rewrites task names and `depends_on` of dependents |
| `kind` default | `graph.ex:416-418` | anything not `"review"` becomes `:task` |
| Review tasks: no `command` required | `graph.ex:420-429`, `validate.ex:230-253` | command-required rule does not apply |
| Regular tasks: gates exempt from `command` rule | `validate.ex:230-253` | tasks with `gate` set bypass the requirement |

## Validation boundaries

| Layer | Responsibility |
|---|---|
| **JSON Schema** (this artifact) | Wire shape: types, enums, required fields, known-field sets. No cross-task semantics. |
| **Engine validation** (`core/lib/sykli/validate.ex`, `core/lib/sykli/graph.ex`) | Cross-task semantics: unique names, no self-deps, no missing deps, no cycles, command required (with exceptions), artifact references resolvable. |
| **SDK validation** (per-SDK pre-emit) | Subset of engine validation, plus stricter SDK-specific rules: K8s memory/CPU regex (Go/Rust/Elixir/Python), Vault `#` separator (Elixir), structured `ValidationError` types (TS, Python). |
| **Runtime / executor** | Out of scope for this schema. Executes the validated graph; enforces timeouts, retries, runtime availability. |

A payload that satisfies the JSON Schema may still be rejected by the engine (e.g., a cycle). A payload the engine accepts may exceed schema strictness (e.g., contains unknown fields). SDKs aim to emit JSON that satisfies both.

## Versioning decision

The top-level `version` field is the Sykli pipeline wire-format/schema version.
It names the version of the pipeline document shape shared between SDKs, schema
tooling, and the engine parser.

It is **not** an execution capability version. It does not mean "run with v1
features" or "run with v2 features" at execution time, and the current engine
does not use it to choose parser or executor behavior. It is also not the
version of a particular SDK package, engine release, runtime, or JSON Schema
draft.

Current behavior is advisory and permissive: SDKs emit `version`, the canonical
schema requires `"1"` or `"2"`, and the engine ignores the value. This means
`version` is useful today as SDK/schema contract metadata, but it is not yet an
engine-enforced compatibility boundary.

`version: "1"` means the baseline task graph format: top-level `tasks` and
regular task fields such as `name`, `command`, `depends_on`, `env`, `inputs`,
`outputs`, `when`, `secrets`, `retry`, and `timeout`. It does not require
top-level resource declarations. SDKs currently emit `"1"` when no
resource-aware features are used.

`version: "2"` means the resource-aware pipeline format. It covers the baseline
task graph plus resource and execution-environment metadata such as top-level
`resources`, directory and cache resources, task `mounts`, task `container`, and
related cache/resource execution metadata already present in the canonical
schema. SDKs currently emit `"2"` when containers, mounts, directory resources,
or cache resources are used.

Future engine behavior should become version-aware in a later implementation
phase:

- accept known supported pipeline wire-format versions
- reject unknown future versions by default
- allow unknown future versions only through an explicit compatibility mode, if
  such a mode is intentionally designed
- never silently reinterpret a newer document as an older version

SDK auto-detection of `"1"` vs `"2"` should continue for now. This is
transitional and reflects current SDK output. Long term, SDKs should either
infer the minimum required wire-format version from the features used, or allow
an explicit override only when that override is safe. SDKs must not let callers
force an older version when the document uses fields that require a newer wire
format.

Future pipeline versions should be monotonic and feature-based: a document's
`version` is the minimum pipeline wire-format version required to preserve its
meaning. Older engines may reject newer documents; newer engines should continue
accepting older supported documents. New versions may add fields or semantics,
but must not depend on older engines silently ignoring those additions. Do not
design or reserve the contents of `version: "3"` until a concrete wire-format
change requires it.

The migration from today's advisory field to real version-aware parsing should
happen in small steps:

1. Keep current SDK output and schema values unchanged.
2. Document the intended meaning of `"1"` and `"2"` in the human-readable
   contract.
3. Add engine parsing that reads the top-level `version` and recognizes the
   currently supported versions.
4. Initially preserve behavior for `"1"` and `"2"` while making unknown future
   versions fail clearly.
5. Only after parser support exists, introduce version-gated behavior for any
   future wire-format changes.

## Removed fields

### `target`

`target` was previously emitted by SDKs as a per-task executor label such as
`"local"`, `"docker"`, or `"k8s"`, but the engine parser ignored it and the
executor did not honor it. It was removed from the canonical SDK-emitted
contract because it had no execution semantics and could mislead users or agents
into assuming behavior that did not exist.

Canonical SDK output must not emit `target`, and the JSON Schema rejects it as
an unknown task field. Existing engines may still ignore incoming `target`
fields for compatibility because the engine parser is permissive, but that
permissive behavior is not part of the canonical contract.

Use concrete execution requirement fields instead: `container`, `resources`,
`mounts`, `k8s`, `services`, `workdir`, and `env`. This removal does not
introduce a replacement field.

## Known contract gaps

These are **descriptive, not prescriptive**. The schema documents current behavior; resolving these is Phase 2C / future work.

1. **`version` is advisory only today.** SDKs emit `"1"` or `"2"`; engine ignores. This document defines it as the pipeline wire-format/schema version and describes the migration path to version-aware parsing.
2. **Review nodes are Go-only.** Engine supports `kind: "review"` and the four review-only fields, but only the Go SDK constructs them. No conformance coverage.
3. **`verify` and `oidc` are reserved with no SDK emit.** Engine reads them; SDKs have no API. Either implement SDK support or drop from the schema once a decision lands.
4. **`history_hint` is engine-internal.** SDKs MUST NOT emit. Schema marks `readOnly` for clarity.
5. **TypeScript K8s interface drift.** `K8sOptions` interface declares 15 fields; only 4 are serialized. The other 11 silently disappear at emit. The schema reflects the wire contract (4 fields); the TypeScript drift is a TS-side issue, not a schema issue.
6. **SDK validation rigor varies.** K8s memory/CPU regex: Go/Rust/Elixir/Python yes, TypeScript no. Vault `#` separator: Elixir only. Structured `ValidationError` with codes: TypeScript and Python only. The schema documents what the engine accepts (the union); each SDK's README describes its own stricter checks.
7. **Unknown fields are ignored by engine.** The canonical schema rejects them. SDKs are expected to align with the schema, not the engine's permissiveness.

## Out of scope

The following Phase 3 fields are **not** included in this schema:

- `task_type` (closed enum classifying compute / validation / reasoning tasks)
- Structured `inputs` (typed: `files | env | secret | artifact`)
- Structured `outputs` (typed: `file | report | artifact` with format)
- `success_criteria` (first-class assertions beyond exit code)
- `side_effects` (closed-vocab list of network / filesystem / database effects)
- `expected` (duration / memory / non-zero exit codes for planning)

These belong to the agent-native semantics work that Phase 3 will design. Adding them now would conflate descriptive schema (what the contract is today) with prescriptive design (what the contract should become).
