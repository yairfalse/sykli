#!/usr/bin/env python3
"""Validate conformance case JSON files against the canonical pipeline schema."""

from __future__ import annotations

import json
import sys
from pathlib import Path

try:
    import jsonschema
except ImportError:
    print(
        "ERROR: missing Python package 'jsonschema'.\n"
        "Install it in your development environment, for example:\n"
        "  python3 -m pip install jsonschema",
        file=sys.stderr,
    )
    sys.exit(2)


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "schemas" / "sykli-pipeline.schema.json"
CASES_DIR = ROOT / "tests" / "conformance" / "cases"


def load_json(path: Path) -> object:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def format_error(error: jsonschema.ValidationError) -> str:
    location = "/".join(str(part) for part in error.absolute_path)
    if not location:
        location = "<root>"
    return f"{location}: {error.message}"


def main() -> int:
    try:
        schema = load_json(SCHEMA_PATH)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL {SCHEMA_PATH.relative_to(ROOT)}")
        print(f"  could not load schema: {exc}")
        print("Summary: 0 passed, 1 failed")
        return 1

    try:
        jsonschema.Draft202012Validator.check_schema(schema)
    except jsonschema.SchemaError as exc:
        print(f"FAIL {SCHEMA_PATH.relative_to(ROOT)}")
        print(f"  invalid schema: {exc.message}")
        print("Summary: 0 passed, 1 failed")
        return 1

    validator = jsonschema.Draft202012Validator(schema)
    passed = 0
    failed = 0

    for path in sorted(CASES_DIR.glob("*.json")):
        rel_path = path.relative_to(ROOT)
        try:
            data = load_json(path)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"FAIL {rel_path}")
            print(f"  could not load JSON: {exc}")
            failed += 1
            continue

        errors = sorted(validator.iter_errors(data), key=lambda err: list(err.absolute_path))
        if errors:
            print(f"FAIL {rel_path}")
            for error in errors:
                print(f"  {format_error(error)}")
            failed += 1
        else:
            print(f"PASS {rel_path}")
            passed += 1

    print(f"Summary: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
