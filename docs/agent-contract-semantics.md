# Agent-Native Contract Semantics

## Status

This is a design document for Phase 3. It defines future semantic contract
fields for the Sykli pipeline contract.

This document does not change the current wire format by itself. It is
normative for future Phase 3 implementation PRs: examples are illustrative, but
rules and definitions are binding.

JSON remains the canonical wire format. The JSON Schema remains the canonical
machine contract.

## Thesis

Phase 3 moves Sykli from "describes how to run a graph" to "describes what the
graph means."

Commands are implementation. They are still necessary for executable tasks, but
they are a poor semantic interface for agents. A shell command can imply a test,
a build, a deploy, a migration, or a publish operation, but agents should not
need to reverse-engineer that meaning from command strings.

The contract should describe intent, expectations, and boundaries. Typed
semantic fields let agents and tools reason about execution without parsing
shell command strings to understand what kind of work a node performs.

## Existing concepts and separation of meaning

Sykli currently has graph node kinds:

- `kind` = graph node kind.
- Current values are `task` and `review`.
- `task` is executable.
- `review` is non-executable.

Future Phase 3 fields must preserve this separation:

- `task_type` = semantic class of an executable task.
- `task_type` applies only to `kind: "task"`.
- `task_type` must not appear on review nodes.
- `primitive` = semantic class of a review node.
- `primitive` applies only to `kind: "review"`.

Do not duplicate meaning across `kind`, `task_type`, and `primitive`.

Examples:

- A lint command that runs as a process is `kind: "task"` with
  `task_type: "lint"`.
- A lint review performed by an agent/reasoning primitive is `kind: "review"`
  with `primitive: "lint"`.
- A review node must not also declare `task_type: "lint"`.

## Strictness model

### 1. Schema validation is mandatory and authoritative

The canonical JSON Schema defines allowed fields, types, enum values, and
applicability constraints. SDKs and the engine should reject malformed pipeline
documents.

Examples:

- Unknown `task_type` = schema error.
- `task_type` on a review node = schema error.
- Review node with `command` = schema error.

### 2. Semantic linting is advisory

Sykli may provide warnings for suspicious, incomplete, or weak declarations.
These warnings are not parse errors.

Examples:

- `deploy` without a declared infrastructure effect = linter warning, not
  schema error.
- `migrate` without a declared database or persistent-state effect = linter
  warning, not schema error.

### 3. Runtime enforcement is out of scope

Sykli validates declarations. Sykli may lint declarations. Sykli does not
enforce declared runtime behavior.

Sykli does not sandbox syscalls, network access, filesystem writes, external
API calls, or database writes. Sykli does not verify at runtime that declared
capabilities or effects match observed process behavior.

Declarations are contract metadata for agents, auditors, reviewers, and
downstream tools. They are descriptive, not punitive.

This boundary is internal to Sykli:

- Sykli describes and runs graphs of work.
- A contract layer is not a policy engine.
- Runtime enforcement would require sandbox/isolation behavior Sykli does not
  own.
- Enforced declarations tend to rot into defensive over-declaration.

Descriptive declarations are less likely to degrade into defensive
over-declaration because a missing declaration does not kill execution.

Example:

- A task declaring no `network` capability but using the network at runtime is
  out of scope for Sykli enforcement.

## Versioning rule

The existing top-level `version` is the pipeline wire-format/schema version.
Phase 3 must not introduce a second `contract_version`.

Adding typed semantic fields is a schema evolution event. The first typed
semantic field, `task_type`, requires `version: "3"`.

The version meanings are:

- `version: "1"` = baseline task graph format.
- `version: "2"` = resource-aware format.
- `version: "3"` = semantic contract format, beginning with `task_type`.

The first `version: "3"` implementation must not add other Phase 3 fields just
because the version becomes `"3"`.

The engine accepts only explicitly supported pipeline wire-format versions.
Missing, empty, malformed, or unsupported future versions are rejected. Do not
make `version` decorative again.

## Semantic layers

### Layer 1 - Classification: `task_type`

Purpose: classify the semantic purpose of an executable task.

Rules:

- Optional.
- Applies only to `kind: "task"`.
- Rejected on `kind: "review"`.
- Does not change execution behavior.
- Helps agents reason without parsing `command`.
- Should be a closed enum.
- Do not include `custom` in the first implementation.
- No free-form marketing tags.

The initial enum is exactly these 12 values. Each value has a normative
definition:

- `build`: Produces compiled or generated artifacts from source inputs.
- `test`: Executes assertions whose pass/fail result verifies code, artifact,
  or system behavior.
- `lint`: Checks source, configuration, or metadata against style, convention,
  or static correctness rules without intentionally rewriting it.
- `format`: Rewrites source, configuration, or metadata into a canonical
  format.
- `scan`: Analyzes source, dependencies, artifacts, or images for findings such
  as security, license, dependency, or quality issues.
- `package`: Assembles existing build outputs into a distributable artifact.
- `publish`: Uploads, registers, or exposes an artifact outside the local
  execution environment.
- `deploy`: Changes a runtime environment to use a new artifact,
  configuration, or version.
- `migrate`: Changes persisted state, data shape, or schema.
- `generate`: Produces source, configuration, or artifacts from templates,
  schemas, models, or other inputs.
- `verify`: Checks that an existing invariant holds without primarily
  producing artifacts or changing runtime state.
- `cleanup`: Removes temporary/generated resources or restores local execution
  state.

Boundary notes:

- `test` vs `verify`: use `test` when the task executes assertions for code,
  artifact, or system behavior; use `verify` when checking an existing
  invariant without primarily exercising a test suite.
- `lint` vs `scan`: use `lint` for style, convention, or static correctness;
  use `scan` for findings-oriented analysis such as security, license,
  dependency, or quality reports.
- `format` vs `lint`: use `format` when the task intentionally rewrites files;
  use `lint` when it checks and reports without intentionally rewriting.
- `build` vs `package`: use `build` when producing artifacts from source; use
  `package` when assembling existing outputs into a distributable artifact.
- `package` vs `publish`: use `package` for local artifact assembly; use
  `publish` when uploading, registering, or exposing the artifact outside the
  local execution environment.
- `deploy` vs `migrate`: use `deploy` when changing a runtime environment to
  use a new artifact, configuration, or version; use `migrate` when changing
  persisted state, data shape, or schema.

### Layer 2 - Verification: `success_criteria`

Purpose: describe how success is known beyond process exit.

Rules:

- Optional.
- Default success remains exit code 0.
- Criteria array is conjunctive: all criteria must pass.
- Do not introduce OR semantics initially.
- `success_criteria` is intended to be engine-checkable.
- Implemented criteria may affect the task result after command execution.
- Do not make outputs automatically imply success.

Declared `outputs` are artifact expectations, not success criteria by
themselves.

Example:

If `outputs: { "binary": "dist/app" }` is declared, that does not
automatically mean `dist/app` is checked as a success condition. If the author
wants that check, they must declare `success_criteria`.

Initial criterion types:

- `exit_code`
- `file_exists`
- `file_non_empty`

Future possibilities, not part of the first implementation:

- `json_path`
- `regex_match`
- `coverage_threshold`
- `junit_report_valid`
- `artifact_declared`
- `outputs_exist`

### Layer 3 - Boundaries: `capabilities` and `effects`

Purpose: separate what a task expects to access from what it may change.

Definitions:

- `capabilities` = what the task expects to use or access.
- `effects` = what the task may change in the world.

These are descriptive declarations, not permissions. A missing capability does
not cause Sykli to kill the task at runtime. A declared effect does not grant
permission.

Possible capability enum:

- `network`
- `secret_read`
- `filesystem_write`
- `container_runtime`
- `package_registry_access`
- `cloud_api_access`

Possible effect enum:

- `filesystem_write_outside_outputs`
- `artifact_publish`
- `external_api_call`
- `database_write`
- `infrastructure_change`
- `persistent_state_change`
- `irreversible_change`

Why split them:

- Sandbox/planning question: "Can this task run in this environment?" maps to
  `capabilities`.
- Risk/audit question: "What can this task change?" maps to `effects`.

Linter examples:

- `deploy` without `infrastructure_change` may warn.
- `migrate` without `database_write` or `persistent_state_change` may warn.
- Broad capabilities with no corresponding effects may warn.

### Layer 4 - Data contracts: typed inputs and outputs

Existing `inputs` and `outputs` keep their current meanings. Phase 3 must use
additive evolution for richer semantics. Do not redefine `inputs` or `outputs`
in place.

Possible future fields:

- `input_contract`
- `output_contract`

Additive fields may supersede current fields over time, but existing fields are
not silently reinterpreted.

Structured input/output design is intentionally later than `task_type` and
`success_criteria`. It touches the artifact model and must be handled
carefully.

### Layer 5 - Planning expectations

Possible future field:

- `expected`

Purpose: describe expected duration, resource usage, and planning hints.

Examples:

- `duration_seconds`
- `memory_mb`
- `cpu_millis`
- `disk_mb`
- `network`
- `cost_hint`

Planning expectations are useful for planning and anomaly detection, but they
are not part of the first implementation.

### Layer 6 - Determinism and reproducibility

Review nodes already have `deterministic`. Executable tasks may later need
deterministic/reproducibility semantics.

Do not overload review-node `deterministic`. A possible future shape might live
under an execution/semantic properties object. Do not implement this in the
first Phase 3 slice.

### Layer 7 - Failure semantics

Existing `ai_hooks` remains an agent behavior hint layer. Typed semantic fields
describe the task. `ai_hooks` describes how an agent should interact with or
respond to the task.

Do not move semantic meaning into `ai_hooks`.

`ai_hooks.on_fail` is not a replacement for typed failure semantics. Failure
semantics may be designed later, but not in the first Phase 3 slice.

## SDK typing model

Typed contract = JSON Schema + SDK-level validation + engine validation where
needed.

Each SDK should implement typing idiomatically:

- Rust: enums / typed structs.
- TypeScript: string union types.
- Python: `Literal` / dataclass or runtime validation.
- Go: typed constants + validation.
- Elixir: `@type` specs + guards/validators.

Wire format remains JSON strings and objects.

Example:

- Rust may expose `TaskType::Test`.
- TypeScript may expose `"test"` as a union literal.
- Elixir may accept `:test`.
- All emit `"task_type": "test"`.

## Phase 3B Decision: `task_type`

Phase 3B implements the first agent-native semantic field: `task_type`.

### Version decision

`task_type` requires pipeline `version: "3"`.

Rationale:

- `version` is the pipeline wire-format/schema version.
- Adding typed semantic fields is a schema evolution event.
- If `task_type` is added under `version: "2"`, `version` becomes decorative
  again.
- `version: "3"` marks the first agent-native semantic schema expansion.

Version meanings:

- `version: "1"` = baseline task graph format.
- `version: "2"` = resource-aware format.
- `version: "3"` = semantic contract format, beginning with `task_type`.

The first implementation must not add `success_criteria`, `capabilities`,
`effects`, typed input/output contracts, or other Phase 3 fields just because
the version becomes `"3"`.

### Initial enum decision

The initial `task_type` enum is exactly:

- `build`
- `test`
- `lint`
- `format`
- `scan`
- `package`
- `publish`
- `deploy`
- `migrate`
- `generate`
- `verify`
- `cleanup`

No `custom` value is included in the first implementation.

Normative definitions:

- `build`: Produces compiled or generated artifacts from source inputs.
- `test`: Executes assertions whose pass/fail result verifies code, artifact,
  or system behavior.
- `lint`: Checks source, configuration, or metadata against style, convention,
  or static correctness rules without intentionally rewriting it.
- `format`: Rewrites source, configuration, or metadata into a canonical
  format.
- `scan`: Analyzes source, dependencies, artifacts, or images for findings such
  as security, license, dependency, or quality issues.
- `package`: Assembles existing build outputs into a distributable artifact.
- `publish`: Uploads, registers, or exposes an artifact outside the local
  execution environment.
- `deploy`: Changes a runtime environment to use a new artifact,
  configuration, or version.
- `migrate`: Changes persisted state, data shape, or schema.
- `generate`: Produces source, configuration, or artifacts from templates,
  schemas, models, or other inputs.
- `verify`: Checks that an existing invariant holds without primarily
  producing artifacts or changing runtime state.
- `cleanup`: Removes temporary/generated resources or restores local execution
  state.

Boundary notes:

- `test` vs `verify`: use `test` when the task executes assertions for code,
  artifact, or system behavior; use `verify` when checking an existing
  invariant without primarily exercising a test suite.
- `lint` vs `scan`: use `lint` for style, convention, or static correctness;
  use `scan` for findings-oriented analysis such as security, license,
  dependency, or quality reports.
- `format` vs `lint`: use `format` when the task intentionally rewrites files;
  use `lint` when it checks and reports without intentionally rewriting.
- `build` vs `package`: use `build` when producing artifacts from source; use
  `package` when assembling existing outputs into a distributable artifact.
- `package` vs `publish`: use `package` for local artifact assembly; use
  `publish` when uploading, registering, or exposing the artifact outside the
  local execution environment.
- `deploy` vs `migrate`: use `deploy` when changing a runtime environment to
  use a new artifact, configuration, or version; use `migrate` when changing
  persisted state, data shape, or schema.

### Applicability decision

`task_type` applies only to executable tasks.

Rules:

- `task_type` must not appear on `kind: "review"` nodes.
- Review nodes continue to use `primitive`.
- `task_type` does not change execution behavior.
- `task_type` is semantic metadata for agents, tooling, schema validation, and
  future linting.

Schema behavior for Phase 3B:

- Accept `task_type` only when `version: "3"`.
- Reject unknown `task_type` values.
- Reject `task_type` on review nodes.

### SDK API decision

In the first implementation, SDKs expose explicit `task_type` APIs. SDKs do not
infer `task_type` from arbitrary command strings.

Rationale:

- Inferring from command strings recreates the problem Phase 3 is trying to
  solve.
- Explicit declaration keeps the contract honest.
- Preset inference can be safe only where the preset itself has a known
  semantic purpose.

Likely SDK shapes:

- Go: `.TaskType(sykli.TaskTypeTest)` or equivalent typed constant.
- Rust: `.task_type(TaskType::Test)`.
- TypeScript: `.taskType("test")` with a string union type.
- Python: `.task_type("test")` with runtime validation / `Literal` typing if
  appropriate.
- Elixir: `task_type :test` with guards/validators.

### Preset decision

Presets do not emit `task_type` automatically in the first implementation.

The first implementation should add explicit API support only. Presets may be
updated in a later PR after basic `task_type` conformance is stable.

Rationale:

- Presets are many and language-specific.
- Updating presets immediately increases blast radius.
- Explicit API first gives a clear contract.

### Conformance decision

Phase 3B adds positive and negative validation coverage.

Positive conformance case:

- `23-task-type.json`
- `version: "3"`
- One or more executable tasks with `task_type`.
- At least two `task_type` values, for example `test` and `build`.
- No review node.

Negative coverage:

- Review node with `task_type` must fail schema validation.
- Unknown `task_type` must fail schema validation.
- `version: "2"` with `task_type` must fail schema validation.

Negative cases should be covered by schema validation fixtures and SDK unit
tests. Conformance negative cases may be added if the harness has a clear way
to represent expected schema-validation failures without mixing them with SDK
emission parity.

### Engine/parser validation decision

Phase 3B enforces `task_type` version gating, enum validation, and review-node
rejection through JSON Schema and through minimal engine/parser validation.

## Phase 3C Decision: `success_criteria`

Phase 3C defines typed verification semantics for executable tasks.
`success_criteria` describes how success is known beyond merely running a
command.

### Applicability decision

`success_criteria` applies only to executable tasks: nodes with omitted `kind`
or `kind: "task"`.

Rules:

- `success_criteria` must not appear on `kind: "review"` nodes.
- Review nodes may later get their own review-result semantics, but not
  `success_criteria`.
- `success_criteria` is optional.
- `success_criteria` does not replace `task_type`.

Meaning is separated as follows:

- `kind` = graph node kind.
- `task_type` = executable task semantic class.
- `primitive` = review-node semantic class.
- `success_criteria` = executable task success contract.

### Version decision

`success_criteria` requires pipeline `version: "3"`.

It is part of the semantic contract format introduced by version 3. It must not
be accepted under `version: "1"` or `version: "2"`. Phase 3C must not introduce
a second version field.

### Combination semantics

`success_criteria` is an array. The array is conjunctive: all criteria must
pass.

Example:

```json
[
  { "type": "exit_code", "equals": 0 },
  { "type": "file_exists", "path": "coverage.out" }
]
```

This means `exit_code == 0` AND `coverage.out` exists.

The first implementation must not add OR semantics or a nested boolean
expression language.

### Default success

When `success_criteria` is absent, current behavior remains unchanged. A task
without `success_criteria` succeeds if its process exits successfully according
to current engine behavior.

Conceptually, the implicit default is `exit_code == 0`, but SDKs must not emit
an explicit `exit_code` criterion by default. Presets must not emit
`success_criteria` in the first implementation.

### Engine-checkable semantics

`success_criteria` is intended to become engine-checkable.

Unlike `capabilities` and `effects`, `success_criteria` may affect the task
result after execution. If criteria are implemented, a task should fail when
the command succeeds but a declared success criterion fails.

This does not make Sykli a runtime policy engine. Criteria are post-task
verification checks against declared status or artifacts. They do not sandbox
syscalls, network use, filesystem writes, external API calls, or database
writes.

Phase 3C-1 stores, validates, and emits `success_criteria` only. It does not
wire criteria into executor result, retry, cache, target, or runtime paths. The
engine must not silently pretend to enforce criteria before target-level
checking exists.

The semantic direction remains engine-checkable verification for Phase 3C-2.

### Outputs relationship

Declared `outputs` are artifact expectations. They do not automatically imply
success criteria.

This avoids hidden semantics. `outputs` alone does not mean "file must exist on
success."

Example:

```json
{
  "outputs": { "binary": "dist/app" }
}
```

This does not automatically check that `dist/app` exists.

To require that check, the author must declare:

```json
{
  "success_criteria": [
    { "type": "file_exists", "path": "dist/app" }
  ]
}
```

### Initial criterion types

The first implementation includes only these criterion types.

#### `exit_code`

Shape:

```json
{ "type": "exit_code", "equals": 0 }
```

Rules:

- `equals` is required.
- `equals` must be an integer from 0 through 255.
- `0` is the normal success value.
- Non-zero success values may be documented explicitly when needed.
- Only one `exit_code` criterion may appear on a task.

Schema or engine/SDK validation should reject duplicate `exit_code` criteria.
If this is awkward in JSON Schema, engine and SDK validation must reject it.

#### `file_exists`

Shape:

```json
{ "type": "file_exists", "path": "coverage.out" }
```

Rules:

- `path` is required.
- `path` must be a string.
- `path` is relative to the task `workdir` unless it is absolute.
- The criterion checks existence only.

#### `file_non_empty`

Shape:

```json
{ "type": "file_non_empty", "path": "coverage.out" }
```

Rules:

- `path` is required.
- `path` must be a string.
- The criterion implies file existence during evaluation.
- It is distinct from `file_exists` because it also checks size/content length.

Future candidates, not part of Phase 3C:

- `json_path`
- `regex_match`
- `coverage_threshold`
- `junit_report_valid`
- `artifact_declared`
- `outputs_exist`

### Failure semantics

If the command fails, the task fails as today.

If the command succeeds but a criterion fails, the task fails with a
`success_criteria` failure. The failure should identify which criterion failed
and should not be reported as command failure.

This should become visible to agents and tools as structured failure
information in the future. Phase 3C does not design the full failure taxonomy.

### SDK API decision

SDKs should expose explicit APIs and validate allowed criterion types. They
must not infer criteria from `outputs`, and presets must not emit
`success_criteria` in the first implementation.

Likely SDK shapes:

- Go: `.SuccessCriteria(sykli.ExitCode(0), sykli.FileExists("coverage.out"))`.
- Rust: `.success_criteria([SuccessCriterion::ExitCode(0), SuccessCriterion::FileExists("coverage.out")])`.
- TypeScript: `.successCriteria([{ type: "exit_code", equals: 0 }, { type: "file_exists", path: "coverage.out" }])`.
- Python: `.success_criteria([{"type": "exit_code", "equals": 0}, {"type": "file_exists", "path": "coverage.out"}])`.
- Elixir: `success_criteria [exit_code(0), file_exists("coverage.out")]`.

Task success criteria must not be available on review builders or review
blocks.

### Conformance decision

Future positive conformance should include:

- `version: "3"`.
- An executable task with `task_type` and `success_criteria`.
- `exit_code` plus `file_exists` or `file_non_empty`.
- No review node.

Future negative coverage should include:

- `success_criteria` under `version: "2"` fails.
- `success_criteria` on a review node fails.
- Unknown criterion type fails.
- `file_exists` without `path` fails.
- `exit_code` without `equals` fails.
- Duplicate `exit_code` criteria fail.

Negative cases should be covered by schema validation and SDK or engine tests.
Conformance negative cases may be added if the harness has a clear expected
failure model.

### Linting direction

Semantic linting remains advisory:

- `task_type: "test"` without `success_criteria` may warn, but must not fail.
- A `success_criteria` file path not declared in `outputs` may warn, but must
  not fail.
- A `file_non_empty` path also declared as an output is good, but not required.
- A `deploy` task with only `exit_code` may warn later, but not in the first
  implementation.

### Non-goals for Phase 3C

- OR semantics.
- Nested boolean criteria.
- `json_path`.
- `regex_match`.
- Coverage thresholds.
- JUnit parsing.
- Automatic output existence checks.
- Preset auto-emission.
- `success_criteria` on review nodes.
- Runtime sandboxing.
- `capabilities` / `effects`.
- Failure taxonomy.
- Compact agent projection.

## Phase 3 implementation sequence

### Phase 3A - this document

Design only. No schema, SDK, engine, or conformance changes.

### Phase 3B - `task_type`

First additive semantic field. It requires `version: "3"` and uses the exact
12-value enum defined in this document.

Must include:

- Schema change.
- SDK support across all five SDKs.
- Conformance positive and negative cases.
- Rejection on review nodes.
- Enum validation.

### Phase 3C - `success_criteria`

Add typed verification semantics.

Must include:

- AND semantics.
- No implicit output success.
- First criterion types only.
- Rejection on review nodes.
- Version 3 gating.
- Post-task failure when an implemented criterion fails.

### Phase 3D - `capabilities` / `effects`

Add descriptive boundary metadata. Must remain non-enforcing.

### Phase 3E - typed input/output contracts

Additive design only. Do not mutate existing `inputs`/`outputs` meanings.

## Non-goals

- Runtime enforcement.
- Sandbox/policy engine behavior.
- Compact agent projection format.
- JSON replacement.
- Reintroducing `target`.
- Free-form semantic tags.
- `custom` task type in the first implementation.
- Model-specific review semantics.
- Task-type-specific schema conditionals in the first implementation.
- Rich artifact ontology in the first implementation.

## Resolved Phase 3B parser decision

Direct parser callers can supply JSON that has not passed through schema
validation, so Phase 3B duplicates the three critical `task_type` checks in the
engine/parser:

- Reject `task_type` on review nodes.
- Reject unknown `task_type` values.
- Reject `task_type` unless the top-level version is `"3"`.
