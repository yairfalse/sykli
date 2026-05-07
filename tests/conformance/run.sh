#!/usr/bin/env bash
set -euo pipefail

# SDK Conformance Test Runner
#
# Runs pipeline fixtures in each SDK, captures JSON output,
# and compares against expected output in cases/.
#
# Usage:
#   ./tests/conformance/run.sh              # run all
#   ./tests/conformance/run.sh 01-basic     # run one case
#   ./tests/conformance/run.sh --sdk python # run one SDK

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONF="$ROOT/tests/conformance"
CASES_DIR="$CONF/cases"
FIXTURES_DIR="$CONF/fixtures"
TMP_DIR=$(mktemp -d)
SUPPORTED_SCHEMA_VERSIONS=("1" "2" "3")

trap 'rm -rf "$TMP_DIR"' EXIT

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
FAINT='\033[2m'
NC='\033[0m'

FILTER_CASE=""
FILTER_SDK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sdk)   FILTER_SDK="$2"; shift 2 ;;
    --sdk=*) FILTER_SDK="${1#--sdk=}"; shift ;;
    -*)      echo "Unknown flag: $1"; exit 1 ;;
    *)       FILTER_CASE="$1"; shift ;;
  esac
done

# Detect a Python interpreter that satisfies the Python SDK's >=3.12
# requirement. If not, the Python conformance cases get skipped instead of
# failing — env-only gaps shouldn't break the runner. An explicit
# SYKLI_CONFORMANCE_PYTHON value takes precedence and must satisfy the version
# check; if it doesn't, the runner errors out rather than silently substituting
# a different interpreter (surprising for local devs debugging selection).
SKIP_PYTHON=0
PYTHON_VERSION="not found"
EXPLICIT_PYTHON="${SYKLI_CONFORMANCE_PYTHON:-}"

check_python_version() {
  local candidate="$1"
  local version
  version="$("$candidate" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || true)"
  [[ -n "$version" ]] || return 1
  local py_major="${version%%.*}"
  local py_minor="${version##*.}"
  if (( py_major > 3 )) || (( py_major == 3 && py_minor >= 12 )); then
    echo "$version"
    return 0
  fi
  echo "$version"
  return 2
}

if [[ -n "$EXPLICIT_PYTHON" ]]; then
  if version=$(check_python_version "$EXPLICIT_PYTHON"); then
    SYKLI_CONFORMANCE_PYTHON="$EXPLICIT_PYTHON"
    PYTHON_VERSION="$version"
  else
    rc=$?
    if (( rc == 2 )); then
      echo "ERROR: SYKLI_CONFORMANCE_PYTHON=$EXPLICIT_PYTHON reports Python $version; SDK requires >=3.12." >&2
    else
      echo "ERROR: SYKLI_CONFORMANCE_PYTHON=$EXPLICIT_PYTHON could not be invoked or did not report a version." >&2
    fi
    echo "  Unset SYKLI_CONFORMANCE_PYTHON to enable auto-detection, or point it at Python >=3.12." >&2
    exit 1
  fi
else
  for candidate in \
    "$ROOT/sdk/python/.venv/bin/python" \
    "python3.14" \
    "python3.13" \
    "python3.12" \
    "python3"; do
    if version=$(check_python_version "$candidate"); then
      SYKLI_CONFORMANCE_PYTHON="$candidate"
      PYTHON_VERSION="$version"
      break
    elif [[ "$PYTHON_VERSION" == "not found" && -n "${version:-}" ]]; then
      PYTHON_VERSION="$version"
    fi
  done

  if [[ -z "${SYKLI_CONFORMANCE_PYTHON:-}" ]]; then
    SKIP_PYTHON=1
  fi
fi

if [[ "$SKIP_PYTHON" -eq 1 ]]; then
  echo "⚠ Python SDK cases will be skipped (Python: $PYTHON_VERSION; SDK requires >=3.12)"
  echo "  CI must run Python conformance; local devs need Python 3.12+ to exercise it."
  echo ""
fi

# Schema validation runs only when we have a usable Python with the jsonschema
# package available. Missing-package failures shouldn't break the runner for
# devs without jsonschema installed; CI installs it explicitly.
echo "Schema Validation"
if [[ "$SKIP_PYTHON" -eq 1 ]]; then
  echo "⚠ skipped — no Python >=3.12 available"
elif ! "$SYKLI_CONFORMANCE_PYTHON" -c "import jsonschema" >/dev/null 2>&1; then
  echo "⚠ skipped — 'jsonschema' package not installed for $SYKLI_CONFORMANCE_PYTHON"
  echo "  Install with: $SYKLI_CONFORMANCE_PYTHON -m pip install jsonschema"
else
  "$SYKLI_CONFORMANCE_PYTHON" "$ROOT/scripts/validate-conformance-schema.py"
fi
echo ""

# Normalize JSON for comparison: sort keys, compact, normalize provides without value
normalize_json() {
  python3 -c "
import json, sys
data = json.load(sys.stdin)

def normalize(obj):
    if isinstance(obj, dict):
        return {k: normalize(v) for k, v in sorted(obj.items())}
    elif isinstance(obj, list):
        return [normalize(v) for v in obj]
    return obj

print(json.dumps(normalize(data), sort_keys=True, separators=(',', ':')))
  "
}

json_version() {
  python3 -c "
import json, sys
data = json.load(sys.stdin)
version = data.get('version')
if not isinstance(version, str):
    sys.exit(2)
print(version)
"
}

supported_schema_version() {
  local version="$1"
  local supported
  for supported in "${SUPPORTED_SCHEMA_VERSIONS[@]}"; do
    [[ "$version" == "$supported" ]] && return 0
  done
  return 1
}

# SDK runners — each captures JSON to stdout
run_go() {
  local fixture="$1"
  local tmp_main="$TMP_DIR/go_main.go"
  cp "$fixture" "$tmp_main"
  cd "$ROOT/sdk/go"
  go run "$tmp_main" --emit 2>/dev/null
}

run_python() {
  local fixture="$1"
  cd "$ROOT/sdk/python"
  PYTHONPATH="$ROOT/sdk/python/src" "$SYKLI_CONFORMANCE_PYTHON" "$fixture" --emit 2>/dev/null
}

run_typescript() {
  local fixture="$1"
  cd "$ROOT/sdk/typescript"
  npx tsx "$fixture" --emit 2>/dev/null
}

run_rust() {
  local fixture="$1"
  local tmp_proj="$TMP_DIR/rust_conformance"
  mkdir -p "$tmp_proj/src"
  cat > "$tmp_proj/Cargo.toml" << TOML
[package]
name = "conformance"
version = "0.1.0"
edition = "2021"
[dependencies]
sykli = { path = "$ROOT/sdk/rust" }
TOML
  cp "$fixture" "$tmp_proj/src/main.rs"
  cd "$tmp_proj"
  cargo run --quiet -- --emit 2>/dev/null
}

run_elixir() {
  local fixture="$1"
  cd "$ROOT/sdk/elixir"
  mix run "$fixture" -- --emit 2>/dev/null
}

PASS=0
FAIL=0
SKIP=0

run_case() {
  local case_name="$1"
  local expected_file="$CASES_DIR/${case_name}.json"

  if [[ ! -f "$expected_file" ]]; then
    echo -e "  ${YELLOW}?${NC} $case_name — no expected output"
    SKIP=$((SKIP + 1))
    return
  fi

  local expected
  expected=$(normalize_json < "$expected_file")

  local expected_version
  if ! expected_version=$(json_version < "$expected_file"); then
    echo -e "  ${RED}✗${NC} $case_name — expected output has missing or malformed version"
    FAIL=$((FAIL + 1))
    return
  fi

  if ! supported_schema_version "$expected_version"; then
    echo -e "  ${RED}✗${NC} $case_name — expected output uses unsupported version $expected_version"
    FAIL=$((FAIL + 1))
    return
  fi

  local sdks=("go" "python" "typescript" "rust" "elixir")

  for sdk in "${sdks[@]}"; do
    if [[ -n "$FILTER_SDK" && "$sdk" != "$FILTER_SDK" ]]; then
      continue
    fi

    if [[ "$sdk" == "python" && "$SKIP_PYTHON" -eq 1 ]]; then
      echo -e "  ${YELLOW}○${NC} $case_name/$sdk — skipped (Python 3.12+ required, found $PYTHON_VERSION)"
      SKIP=$((SKIP + 1))
      continue
    fi

    local ext
    case "$sdk" in
      go)         ext="go" ;;
      python)     ext="py" ;;
      typescript) ext="ts" ;;
      rust)       ext="rs" ;;
      elixir)     ext="exs" ;;
    esac

    local fixture="$FIXTURES_DIR/$sdk/${case_name}.${ext}"

    if [[ ! -f "$fixture" ]]; then
      echo -e "  ${YELLOW}○${NC} $case_name/$sdk — no fixture"
      SKIP=$((SKIP + 1))
      continue
    fi

    if [[ "$sdk" == "python" && -z "$SYKLI_CONFORMANCE_PYTHON" ]]; then
      echo -e "  ${YELLOW}○${NC} $case_name/$sdk — skipped (no Python >=3.12 found)"
      SKIP=$((SKIP + 1))
      continue
    fi

    local actual_raw actual
    local err_file="$TMP_DIR/err_${sdk}_${case_name}"

    if actual_raw=$("run_${sdk}" "$fixture" 2>"$err_file"); then
      local actual_version
      if ! actual_version=$(echo "$actual_raw" | json_version); then
        echo -e "  ${RED}✗${NC} $case_name/$sdk — emitted missing or malformed version"
        FAIL=$((FAIL + 1))
        continue
      fi

      if ! supported_schema_version "$actual_version"; then
        echo -e "  ${RED}✗${NC} $case_name/$sdk — emitted unsupported version $actual_version"
        FAIL=$((FAIL + 1))
        continue
      fi

      actual=$(echo "$actual_raw" | normalize_json)

      if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${GREEN}✓${NC} $case_name/$sdk"
        PASS=$((PASS + 1))
      else
        echo -e "  ${RED}✗${NC} $case_name/$sdk — output mismatch"
        # Show diff
        diff <(echo "$expected" | python3 -m json.tool) \
             <(echo "$actual" | python3 -m json.tool) || true
        echo ""
        FAIL=$((FAIL + 1))
      fi
    else
      echo -e "  ${RED}✗${NC} $case_name/$sdk — execution failed"
      if [[ -s "$err_file" ]]; then
        echo -e "    ${FAINT}$(head -3 "$err_file")${NC}"
      fi
      FAIL=$((FAIL + 1))
    fi
  done
}

run_negative_case() {
  local case_name="$1"

  local sdks=("go" "python" "typescript" "rust" "elixir")

  for sdk in "${sdks[@]}"; do
    if [[ -n "$FILTER_SDK" && "$sdk" != "$FILTER_SDK" ]]; then
      continue
    fi

    if [[ "$sdk" == "python" && "$SKIP_PYTHON" -eq 1 ]]; then
      echo -e "  ${YELLOW}○${NC} $case_name/$sdk — skipped (Python 3.12+ required, found $PYTHON_VERSION)"
      SKIP=$((SKIP + 1))
      continue
    fi

    local ext
    case "$sdk" in
      go)         ext="go" ;;
      python)     ext="py" ;;
      typescript) ext="ts" ;;
      rust)       ext="rs" ;;
      elixir)     ext="exs" ;;
    esac

    local fixture="$FIXTURES_DIR/$sdk/${case_name}.${ext}"

    if [[ ! -f "$fixture" ]]; then
      echo -e "  ${YELLOW}○${NC} $case_name/$sdk — no fixture"
      SKIP=$((SKIP + 1))
      continue
    fi

    if [[ "$sdk" == "python" && -z "$SYKLI_CONFORMANCE_PYTHON" ]]; then
      echo -e "  ${YELLOW}○${NC} $case_name/$sdk — skipped (no Python >=3.12 found)"
      SKIP=$((SKIP + 1))
      continue
    fi

    local err_file="$TMP_DIR/err_${sdk}_${case_name}"

    if "run_${sdk}" "$fixture" >"$TMP_DIR/out_${sdk}_${case_name}" 2>"$err_file"; then
      echo -e "  ${RED}✗${NC} $case_name/$sdk — expected failure but got exit 0"
      FAIL=$((FAIL + 1))
    else
      echo -e "  ${GREEN}✓${NC} $case_name/$sdk (expected failure)"
      PASS=$((PASS + 1))
    fi
  done
}

echo "SDK Conformance Tests"
echo ""

if [[ -n "$FILTER_CASE" ]]; then
  if [[ "$FILTER_CASE" == err-* ]]; then
    run_negative_case "$FILTER_CASE"
  else
    run_case "$FILTER_CASE"
  fi
else
  # Happy path tests
  for case_file in "$CASES_DIR"/*.json; do
    case_name=$(basename "$case_file" .json)
    run_case "$case_name"
  done

  # Negative tests
  for case_file in "$CASES_DIR"/err-*.txt; do
    [[ -f "$case_file" ]] || continue
    case_name=$(basename "$case_file" .txt)
    run_negative_case "$case_name"
  done
fi

echo ""
echo -e "${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

if [[ "$SKIP_PYTHON" -eq 1 && ( "${CI:-}" == "true" || "$FILTER_SDK" == "python" ) ]]; then
  echo -e "${RED}Python SDK conformance was skipped; install Python 3.12+${NC}"
  exit 2
fi
