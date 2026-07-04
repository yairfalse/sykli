#!/usr/bin/env python3
"""Check generated contract vocabulary copies against schemas/vocabulary.json.

This is intentionally conservative: the manifest is the source of truth, and
the script fails if any committed SDK/schema/engine copy drifts. Use --emit to
print generated fragments for manual updates.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "schemas" / "vocabulary.json"


def read_text(path: str) -> str:
    return (ROOT / path).read_text()


def manifest() -> dict[str, list[str]]:
    with MANIFEST.open() as handle:
        return json.load(handle)


def schema() -> dict:
    with (ROOT / "schemas" / "sykli-pipeline.schema.json").open() as handle:
        return json.load(handle)


def regex_values(path: str, pattern: str) -> set[str]:
    values: set[str] = set()
    for match in re.findall(pattern, read_text(path)):
        if isinstance(match, tuple):
            values.update(value for value in match if value)
        else:
            values.add(match)
    return values


def string_literals_in_block(path: str, pattern: str) -> set[str]:
    match = re.search(pattern, read_text(path), re.S)
    if not match:
        return set()
    return set(re.findall(r"""["']([^"']+)["']""", match.group(1)))


def atoms_in_block(path: str, pattern: str) -> set[str]:
    match = re.search(pattern, read_text(path), re.S)
    if not match:
        return set()
    return set(re.findall(r":([a-z_]+)", match.group(1)))


def schema_task_types() -> set[str]:
    return set(schema()["$defs"]["task"]["properties"]["task_type"]["enum"])


def schema_success_criteria() -> set[str]:
    defs = schema()["$defs"]
    return {
        defs["exitCodeCriterion"]["properties"]["type"]["const"],
        defs["fileExistsCriterion"]["properties"]["type"]["const"],
        defs["fileNonEmptyCriterion"]["properties"]["type"]["const"],
    }


def schema_evidence_required() -> set[str]:
    return set(schema()["$defs"]["evidenceRequirement"]["properties"]["type"]["enum"])


def schema_actor_kind() -> set[str]:
    return set(schema()["$defs"]["actor"]["properties"]["kind"]["enum"])


def conformance_task_types() -> set[str]:
    with (ROOT / "tests/conformance/cases/23-task-type.json").open() as handle:
        data = json.load(handle)
    return {task["task_type"] for task in data["tasks"]}


def check_equal(name: str, expected: set[str], actual: set[str], errors: list[str]) -> None:
    if expected != actual:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        errors.append(f"{name} drifted: missing={missing} extra={extra}")


def check() -> int:
    vocab = manifest()
    task_types = set(vocab["task_type"])
    success_criteria = set(vocab["success_criteria"])
    evidence_required = set(vocab["evidence_required"])
    actor_kind = set(vocab["actor_kind"])
    errors: list[str] = []

    check_equal("schema task_type", task_types, schema_task_types(), errors)
    check_equal(
        "engine task_type",
        task_types,
        set(
            re.search(
                r"@values\s+~w\(([^)]+)\)",
                read_text("core/lib/sykli/task_type.ex"),
            )
            .group(1)
            .split()
        ),
        errors,
    )
    check_equal(
        "go task_type",
        task_types,
        regex_values("sdk/go/sykli.go", r'TaskType\w+\s+TaskType\s+=\s+"([^"]+)"'),
        errors,
    )
    check_equal(
        "rust task_type",
        task_types,
        regex_values("sdk/rust/src/lib.rs", r'TaskType::\w+\s+=>\s+"([^"]+)"'),
        errors,
    )
    check_equal(
        "typescript task_type",
        task_types,
        string_literals_in_block(
            "sdk/typescript/src/index.ts",
            r"const TASK_TYPES = \[([^\]]+)\] as const;",
        ),
        errors,
    )
    check_equal(
        "python task_type",
        task_types,
        string_literals_in_block(
            "sdk/python/src/sykli/__init__.py",
            r"TaskType = Literal\[([^\]]+)\]",
        ),
        errors,
    )
    check_equal(
        "elixir task_type",
        task_types,
        atoms_in_block(
            "sdk/elixir/lib/sykli/task.ex",
            r"@task_types \[([^\]]+)\]",
        ),
        errors,
    )
    check_equal("conformance 23-task-type", task_types, conformance_task_types(), errors)

    check_equal("schema success_criteria", success_criteria, schema_success_criteria(), errors)
    check_equal(
        "engine success_criteria",
        success_criteria,
        set(
            re.search(
                r"@types\s+~w\(([^)]+)\)",
                read_text("core/lib/sykli/success_criteria.ex"),
            )
            .group(1)
            .split()
        ),
        errors,
    )
    check_equal(
        "typescript success_criteria",
        success_criteria,
        regex_values("sdk/typescript/src/index.ts", r"type: '(exit_code|file_exists|file_non_empty)'"),
        errors,
    )
    check_equal(
        "python success_criteria",
        success_criteria,
        regex_values("sdk/python/src/sykli/__init__.py", r'"(exit_code|file_exists|file_non_empty)"'),
        errors,
    )
    check_equal(
        "go success_criteria",
        success_criteria,
        regex_values("sdk/go/sykli.go", r'criterionType:\s+"([^"]+)"'),
        errors,
    )
    check_equal(
        "rust success_criteria",
        success_criteria,
        regex_values(
            "sdk/rust/src/lib.rs",
            r'type_:\s+"(exit_code|file_exists|file_non_empty)"\.to_string\(\)',
        ),
        errors,
    )
    check_equal(
        "elixir success_criteria",
        success_criteria,
        regex_values("sdk/elixir/lib/sykli/dsl.ex", r'"(exit_code|file_exists|file_non_empty)"'),
        errors,
    )

    check_equal("schema evidence_required", evidence_required, schema_evidence_required(), errors)
    check_equal(
        "engine evidence_required",
        evidence_required,
        set(
            re.search(
                r"@types\s+~w\(([^)]+)\)",
                read_text("core/lib/sykli/evidence_requirement.ex"),
            )
            .group(1)
            .split()
        ),
        errors,
    )
    check_equal(
        "typescript evidence_required",
        evidence_required,
        string_literals_in_block(
            "sdk/typescript/src/index.ts",
            r"export type EvidenceRequirement = \{.*?type: ([^;]+);",
        ),
        errors,
    )
    check_equal(
        "python evidence_required",
        evidence_required,
        string_literals_in_block(
            "sdk/python/src/sykli/__init__.py",
            r"types = \{([^}]+)\}",
        ),
        errors,
    )
    check_equal(
        "go evidence_required",
        evidence_required,
        regex_values("sdk/go/sykli.go", r'Evidence\("([^"]+)", name\)|requirementType:\s+"(file)"'),
        errors,
    )
    check_equal(
        "rust evidence_required",
        evidence_required,
        regex_values("sdk/rust/src/lib.rs", r'Self::evidence\("([^"]+)", name\)|type_:\s+"(file)"\.to_string\(\)'),
        errors,
    )
    check_equal(
        "elixir evidence_required",
        evidence_required,
        regex_values("sdk/elixir/lib/sykli/dsl.ex", r'"(file|log|attestation|occurrence|metric|test_report|artifact_ref|custom)"'),
        errors,
    )

    check_equal("schema actor_kind", actor_kind, schema_actor_kind(), errors)
    check_equal(
        "engine actor_kind",
        actor_kind,
        set(
            re.search(
                r"@kinds\s+~w\(([^)]+)\)",
                read_text("core/lib/sykli/actor.ex"),
            )
            .group(1)
            .split()
        ),
        errors,
    )
    check_equal(
        "go actor_kind",
        actor_kind,
        regex_values("sdk/go/sykli.go", r'ActorKind\w+\s+ActorKind\s+=\s+"([^"]+)"'),
        errors,
    )
    check_equal(
        "rust actor_kind",
        actor_kind,
        regex_values("sdk/rust/src/lib.rs", r'ActorKind::\w+\s+=>\s+"([^"]+)"'),
        errors,
    )
    check_equal(
        "typescript actor_kind",
        actor_kind,
        string_literals_in_block(
            "sdk/typescript/src/index.ts",
            r"const ACTOR_KINDS = \[([^\]]+)\] as const;",
        ),
        errors,
    )
    check_equal(
        "python actor_kind",
        actor_kind,
        string_literals_in_block(
            "sdk/python/src/sykli/__init__.py",
            r"ActorKind = Literal\[([^\]]+)\]",
        ),
        errors,
    )
    check_equal(
        "elixir actor_kind",
        actor_kind,
        atoms_in_block(
            "sdk/elixir/lib/sykli/task.ex",
            r"@actor_kinds \[([^\]]+)\]",
        ),
        errors,
    )

    if errors:
        print("Vocabulary drift detected:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print("Vocabulary manifest matches schema, engine, SDKs, and conformance.")
    return 0


def emit() -> None:
    vocab = manifest()
    print("# task_type")
    for value in vocab["task_type"]:
        print(value)
    print("\n# success_criteria")
    for value in vocab["success_criteria"]:
        print(value)
    print("\n# evidence_required")
    for value in vocab["evidence_required"]:
        print(value)
    print("\n# actor_kind")
    for value in vocab["actor_kind"]:
        print(value)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify committed vocabulary copies")
    parser.add_argument("--emit", action="store_true", help="print generated vocabulary fragments")
    args = parser.parse_args()

    if args.emit:
        emit()
        return 0

    return check()


if __name__ == "__main__":
    raise SystemExit(main())
