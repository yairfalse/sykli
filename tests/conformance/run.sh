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
  source .venv/bin/activate 2>/dev/null || true
  PYTHONPATH="$ROOT/sdk/python/src" python3 "$fixture" --emit 2>/dev/null
}

run_typescript() {
  local fixture="$1"
  cd "$ROOT/sdk/typescript"
  npx tsx "$fixture" --emit 2>/dev/null
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

  local sdks=("go" "python" "typescript")

  for sdk in "${sdks[@]}"; do
    if [[ -n "$FILTER_SDK" && "$sdk" != "$FILTER_SDK" ]]; then
      continue
    fi

    local ext
    case "$sdk" in
      go)         ext="go" ;;
      python)     ext="py" ;;
      typescript) ext="ts" ;;
    esac

    local fixture="$FIXTURES_DIR/$sdk/${case_name}.${ext}"

    if [[ ! -f "$fixture" ]]; then
      echo -e "  ${YELLOW}○${NC} $case_name/$sdk — no fixture"
      SKIP=$((SKIP + 1))
      continue
    fi

    local actual_raw actual
    local err_file="$TMP_DIR/err_${sdk}_${case_name}"

    if actual_raw=$("run_${sdk}" "$fixture" 2>"$err_file"); then
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

  local sdks=("go" "python" "typescript")

  for sdk in "${sdks[@]}"; do
    if [[ -n "$FILTER_SDK" && "$sdk" != "$FILTER_SDK" ]]; then
      continue
    fi

    local ext
    case "$sdk" in
      go)         ext="go" ;;
      python)     ext="py" ;;
      typescript) ext="ts" ;;
    esac

    local fixture="$FIXTURES_DIR/$sdk/${case_name}.${ext}"

    if [[ ! -f "$fixture" ]]; then
      echo -e "  ${YELLOW}○${NC} $case_name/$sdk — no fixture"
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
