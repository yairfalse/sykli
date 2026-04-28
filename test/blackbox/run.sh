#!/usr/bin/env bash
#
# sykli black-box test runner
# Reads dataset.json, creates temp fixtures, runs tests, reports results.
#
# Additional Phase 2.5 predicates are backward-compatible:
#   expect_stdout_not_contains: ["text"]   fail if combined output contains any string
#   expect_no_ansi: true                   fail if stdout/stderr contains ANSI CSI escapes
#   expect_json_keys: ["ok", ...]          require exact top-level keys in JSON output
#   expect_json_jq: [".ok == true"]        require every jq expression to evaluate to true
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYKLI_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SYKLI_BIN="${SYKLI_BIN:-$SYKLI_ROOT/core/sykli}"
DATASET="$SCRIPT_DIR/dataset.json"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Counters
PASS=0
FAIL=0
SKIP=0
TOTAL=0
FAILURES=()

# Parse args
FILTER=""
VERBOSE=0
CATEGORY_FILTER=""
for arg in "$@"; do
  case "$arg" in
    --filter=*) FILTER="${arg#--filter=}" ;;
    --verbose|-v) VERBOSE=1 ;;
    --category=*) CATEGORY_FILTER="${arg#--category=}" ;;
    --help|-h)
      echo "Usage: $0 [options]"
      echo "  --filter=PATTERN   Only run tests matching PATTERN (e.g. POS, NEG-001)"
  echo "  --category=CAT     Only run tests in a category prefix"
      echo "  --verbose, -v      Show command output for all tests"
      exit 0
      ;;
  esac
done

# Check prerequisites
if [ ! -f "$SYKLI_BIN" ]; then
  echo -e "${RED}Error: sykli binary not found at $SYKLI_BIN${RESET}"
  echo "Build it with: cd core && mix escript.build"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo -e "${RED}Error: jq is required but not installed${RESET}"
  exit 1
fi

# Portable millisecond timestamp
now_ms() {
  if date +%s%3N 2>/dev/null | grep -qE '^[0-9]{13,}$'; then
    date +%s%3N
  elif command -v perl &>/dev/null; then
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

# Setup temp workspace
WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT

setup_fixture() {
  local test_id="$1"
  local fixture_name="$2"
  local test_dir="$WORKSPACE/$test_id"
  rm -rf "$test_dir"
  mkdir -p "$test_dir"

  case "$fixture_name" in
    empty_dir)
      # No files — that's the point
      ;;
    *)
      local fixture_dir="$FIXTURES_DIR/${fixture_name}"
      local fixture_file="$FIXTURES_DIR/${fixture_name}.exs"

      if [ -d "$fixture_dir" ]; then
        # Directory fixture — copy entire directory contents
        cp -R "$fixture_dir"/* "$test_dir/" 2>/dev/null || true
        cp -R "$fixture_dir"/.[!.]* "$test_dir/" 2>/dev/null || true
        # Rewrite SYKLI_ROOT placeholder to actual project root
        for f in "$test_dir"/go.mod "$test_dir"/package.json "$test_dir"/Cargo.toml; do
          if [ -f "$f" ]; then
            sed -i.bak "s|SYKLI_ROOT|$SYKLI_ROOT|g" "$f" && rm -f "$f.bak"
          fi
        done
        # Install deps for directory fixtures
        if [ -f "$test_dir/package.json" ]; then
          if ! (cd "$test_dir" && npm install --silent 2>/dev/null); then
            echo -e "${RED}npm install failed for fixture: $fixture_name${RESET}" >&2
            return 1
          fi
        fi
      elif [ -f "$fixture_file" ]; then
        cp "$fixture_file" "$test_dir/sykli.exs"
      else
        echo -e "${RED}Missing fixture: $fixture_file${RESET}" >&2
        return 1
      fi
      ;;
  esac
}

check_requires() {
  local requires="$1"
  if [ -z "$requires" ] || [ "$requires" = "null" ]; then
    return 0
  fi
  command -v "$requires" &>/dev/null
}

strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

run_test() {
  local id="$1"
  local name="$2"
  local fixture="$3"
  local cmd="$4"
  local expect_exit="$5"
  local expect_stdout="$6"
  local expect_stdout_contains="$7"
  local expect_json="$8"
  local expect_json_contains="$9"
  local max_duration_ms="${10}"
  local requires="${11}"
  local use_shell="${12}"
  local expect_dir="${13}"
  local expect_stdout_not_contains="${14}"
  local expect_no_ansi="${15}"
  local expect_json_keys="${16}"
  local expect_json_jq="${17}"

  TOTAL=$((TOTAL + 1))

  # Apply filters
  if [ -n "$FILTER" ] && [[ "$id" != *"$FILTER"* ]]; then
    SKIP=$((SKIP + 1))
    return 0
  fi
  if [ -n "$CATEGORY_FILTER" ]; then
    local cat_prefix="${id%%-*}"
    if [ "$cat_prefix" != "$CATEGORY_FILTER" ]; then
      SKIP=$((SKIP + 1))
      return 0
    fi
  fi

  # Check prerequisites
  if ! check_requires "$requires"; then
    SKIP=$((SKIP + 1))
    printf "  ${YELLOW}○ %-10s${RESET} %s ${DIM}(requires: %s)${RESET}\n" "$id" "$name" "$requires"
    return 0
  fi

  # Setup fixture
  if ! setup_fixture "$id" "$fixture"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("$id: missing fixture '$fixture'")
    printf "  ${RED}✗ %-10s${RESET} %s ${DIM}(missing fixture)${RESET}\n" "$id" "$name"
    return 0
  fi

  local test_dir="$WORKSPACE/$id"

  # Replace 'sykli' in command with actual binary path
  local full_cmd="${cmd//SYKLI_ROOT/$SYKLI_ROOT}"
  full_cmd=$(SYKLI_BIN_REPL="$SYKLI_BIN" perl -pe 's/(?<![A-Za-z0-9_.\/-])sykli(?![A-Za-z0-9_.-])/$ENV{SYKLI_BIN_REPL}/g' <<< "$full_cmd")

  # Execute
  local start_ms=$(now_ms)
  local stdout_file="$WORKSPACE/${id}.stdout"
  local stderr_file="$WORKSPACE/${id}.stderr"
  local actual_exit=0

  if [ "$use_shell" = "true" ]; then
    (cd "$test_dir" && bash -c "$full_cmd" >"$stdout_file" 2>"$stderr_file") || actual_exit=$?
  else
    (cd "$test_dir" && $full_cmd >"$stdout_file" 2>"$stderr_file") || actual_exit=$?
  fi

  local end_ms=$(now_ms)
  local duration_ms=$((end_ms - start_ms))

  local stdout_clean
  stdout_clean=$(cat "$stdout_file" | strip_ansi)
  local stderr_clean
  stderr_clean=$(cat "$stderr_file" | strip_ansi 2>/dev/null || true)

  # Combine stdout and stderr for matching (sykli outputs to both)
  local all_output="$stdout_clean
$stderr_clean"

  # Verify expectations
  local failed=0
  local fail_reason=""

  # Exit code
  if [ "$actual_exit" != "$expect_exit" ]; then
    failed=1
    fail_reason="exit code: expected=$expect_exit actual=$actual_exit"
  fi

  # Stdout contains exact string
  if [ $failed -eq 0 ] && [ -n "$expect_stdout" ] && [ "$expect_stdout" != "null" ]; then
    if ! echo "$all_output" | grep -qF "$expect_stdout"; then
      failed=1
      fail_reason="stdout missing: '$expect_stdout'"
    fi
  fi

  # Stdout contains multiple strings
  if [ $failed -eq 0 ] && [ -n "$expect_stdout_contains" ] && [ "$expect_stdout_contains" != "null" ]; then
    local patterns
    patterns=$(echo "$expect_stdout_contains" | jq -r '.[]' 2>/dev/null || true)
    if [ -n "$patterns" ]; then
      while IFS= read -r pattern; do
        if ! echo "$all_output" | grep -qF -- "$pattern"; then
          failed=1
          fail_reason="stdout missing pattern: '$pattern'"
          break
        fi
      done <<< "$patterns"
    fi
  fi

  # Stdout must not contain multiple strings
  if [ $failed -eq 0 ] && [ -n "$expect_stdout_not_contains" ] && [ "$expect_stdout_not_contains" != "null" ]; then
    local forbidden_patterns
    forbidden_patterns=$(echo "$expect_stdout_not_contains" | jq -r '.[]' 2>/dev/null || true)
    if [ -n "$forbidden_patterns" ]; then
      while IFS= read -r pattern; do
        if echo "$all_output" | grep -qF -- "$pattern"; then
          failed=1
          fail_reason="stdout contained forbidden pattern: '$pattern'"
          break
        fi
      done <<< "$forbidden_patterns"
    fi
  fi

  # Raw stdout/stderr must not contain ANSI CSI escapes
  if [ $failed -eq 0 ] && [ "$expect_no_ansi" = "true" ]; then
    if LC_ALL=C grep -q "$(printf '\033')\\[" "$stdout_file" "$stderr_file" 2>/dev/null; then
      failed=1
      fail_reason="output contained ANSI escape codes"
    fi
  fi

  # JSON exact match (subset)
  if [ $failed -eq 0 ] && [ -n "$expect_json" ] && [ "$expect_json" != "null" ]; then
    local actual_json
    actual_json=$(jq '.' "$stdout_file" 2>/dev/null || jq '.' "$stderr_file" 2>/dev/null || true)
    if [ -n "$actual_json" ]; then
      local keys
      keys=$(echo "$expect_json" | jq -r 'keys[]')
      while IFS= read -r key; do
        local expected_val
        expected_val=$(echo "$expect_json" | jq ".$key")
        local actual_val
        actual_val=$(echo "$actual_json" | jq ".$key" 2>/dev/null || echo "null")
        if [ "$expected_val" != "$actual_val" ]; then
          failed=1
          fail_reason="JSON .$key: expected=$expected_val actual=$actual_val"
          break
        fi
      done <<< "$keys"
    else
      failed=1
      fail_reason="no JSON found in output"
    fi
  fi

  # JSON contains (subset match)
  if [ $failed -eq 0 ] && [ -n "$expect_json_contains" ] && [ "$expect_json_contains" != "null" ]; then
    local actual_json
    actual_json=$(jq '.' "$stdout_file" 2>/dev/null || jq '.' "$stderr_file" 2>/dev/null || true)
    if [ -n "$actual_json" ]; then
      local keys
      keys=$(echo "$expect_json_contains" | jq -r 'keys[]')
      while IFS= read -r key; do
        local expected_val
        expected_val=$(echo "$expect_json_contains" | jq ".$key")
        local actual_val
        actual_val=$(echo "$actual_json" | jq ".$key" 2>/dev/null || echo "null")
        if [ "$expected_val" != "$actual_val" ]; then
          failed=1
          fail_reason="JSON .$key: expected=$expected_val actual=$actual_val"
          break
        fi
      done <<< "$keys"
    else
      failed=1
      fail_reason="no JSON found in output"
    fi
  fi

  # JSON top-level keys must match exactly
  if [ $failed -eq 0 ] && [ -n "$expect_json_keys" ] && [ "$expect_json_keys" != "null" ]; then
    local actual_json
    actual_json=$(jq '.' "$stdout_file" 2>/dev/null || jq '.' "$stderr_file" 2>/dev/null || true)
    if [ -n "$actual_json" ]; then
      local expected_keys actual_keys
      expected_keys=$(echo "$expect_json_keys" | jq -r 'sort | join(",")')
      actual_keys=$(echo "$actual_json" | jq -r 'keys | sort | join(",")' 2>/dev/null || true)
      if [ "$expected_keys" != "$actual_keys" ]; then
        failed=1
        fail_reason="JSON keys: expected=$expected_keys actual=$actual_keys"
      fi
    else
      failed=1
      fail_reason="no JSON found in output"
    fi
  fi

  # JSON jq expressions must all evaluate to true
  if [ $failed -eq 0 ] && [ -n "$expect_json_jq" ] && [ "$expect_json_jq" != "null" ]; then
    local actual_json
    actual_json=$(jq '.' "$stdout_file" 2>/dev/null || jq '.' "$stderr_file" 2>/dev/null || true)
    if [ -n "$actual_json" ]; then
      local expressions
      expressions=$(echo "$expect_json_jq" | jq -r '.[]' 2>/dev/null || true)
      while IFS= read -r expression; do
        if [ -z "$expression" ]; then continue; fi
        if ! echo "$actual_json" | jq -e "$expression" >/dev/null 2>&1; then
          failed=1
          fail_reason="JSON jq assertion failed: $expression"
          break
        fi
      done <<< "$expressions"
    else
      failed=1
      fail_reason="no JSON found in output"
    fi
  fi

  # Duration check
  if [ $failed -eq 0 ] && [ -n "$max_duration_ms" ] && [ "$max_duration_ms" != "null" ] && [ "$max_duration_ms" -gt 0 ] 2>/dev/null; then
    if [ "$duration_ms" -gt 0 ] && [ "$duration_ms" -gt "$max_duration_ms" ]; then
      failed=1
      fail_reason="too slow: ${duration_ms}ms > ${max_duration_ms}ms"
    fi
  fi

  # Directory existence check
  if [ $failed -eq 0 ] && [ -n "$expect_dir" ] && [ "$expect_dir" != "null" ]; then
    if [ ! -d "$test_dir/$expect_dir" ]; then
      failed=1
      fail_reason="expected directory '$expect_dir' not found"
    fi
  fi

  # Report result
  local duration_str=""
  if [ "$duration_ms" -gt 0 ]; then
    duration_str=" ${DIM}(${duration_ms}ms)${RESET}"
  fi

  if [ $failed -eq 1 ]; then
    FAIL=$((FAIL + 1))
    FAILURES+=("$id: $fail_reason")
    printf "  ${RED}✗ %-10s${RESET} %s${duration_str}\n" "$id" "$name"
    if [ $VERBOSE -eq 1 ]; then
      echo -e "    ${DIM}Reason: $fail_reason${RESET}"
      echo -e "    ${DIM}Stdout: $(head -3 "$stdout_file" | strip_ansi)${RESET}"
      echo -e "    ${DIM}Stderr: $(head -3 "$stderr_file" | strip_ansi)${RESET}"
    fi
  else
    PASS=$((PASS + 1))
    printf "  ${GREEN}✓ %-10s${RESET} %s${duration_str}\n" "$id" "$name"
  fi
}

# Banner
echo ""
echo -e "${BOLD}${CYAN}━━━ sykli black-box test suite ━━━${RESET}"
echo -e "${DIM}Binary: $SYKLI_BIN${RESET}"
echo -e "${DIM}Dataset: $(jq '.cases | length' "$DATASET") test cases${RESET}"
echo ""

# Run categories in order
for category in POS NEG SYS INT PERF LOAD ABN CACHE JSON DET SDK UI GH; do
  cases=$(jq -c ".cases[] | select(.id | startswith(\"$category\"))" "$DATASET")
  if [ -z "$cases" ]; then continue; fi

  cat_name=$(jq -r ".categories.\"$category\"" "$DATASET")
  echo -e "${BOLD}$cat_name${RESET}"

  while IFS= read -r case_json; do
    id=$(echo "$case_json" | jq -r '.id')
    name=$(echo "$case_json" | jq -r '.name')
    fixture=$(echo "$case_json" | jq -r '.fixture')
    cmd=$(echo "$case_json" | jq -r '.command')
    expect_exit=$(echo "$case_json" | jq -r '.expect_exit')
    expect_stdout=$(echo "$case_json" | jq -r '.expect_stdout // empty')
    expect_stdout_contains=$(echo "$case_json" | jq -c '.expect_stdout_contains // empty')
    expect_json=$(echo "$case_json" | jq -c '.expect_json // empty')
    expect_json_contains=$(echo "$case_json" | jq -c '.expect_json_contains // empty')
    max_duration_ms=$(echo "$case_json" | jq -r '.max_duration_ms // empty')
    requires=$(echo "$case_json" | jq -r '.requires // empty')
    use_shell=$(echo "$case_json" | jq -r '.shell // empty')
    expect_dir=$(echo "$case_json" | jq -r '.expect_dir // empty')
    expect_stdout_not_contains=$(echo "$case_json" | jq -c '.expect_stdout_not_contains // empty')
    expect_no_ansi=$(echo "$case_json" | jq -r '.expect_no_ansi // empty')
    expect_json_keys=$(echo "$case_json" | jq -c '.expect_json_keys // empty')
    expect_json_jq=$(echo "$case_json" | jq -c '.expect_json_jq // empty')

    run_test "$id" "$name" "$fixture" "$cmd" "$expect_exit" \
      "$expect_stdout" "$expect_stdout_contains" "$expect_json" \
      "$expect_json_contains" "$max_duration_ms" "$requires" \
      "$use_shell" "$expect_dir" "$expect_stdout_not_contains" \
      "$expect_no_ansi" "$expect_json_keys" "$expect_json_jq"
  done <<< "$cases"

  echo ""
done

# Summary
echo -e "${BOLD}━━━ Results ━━━${RESET}"
echo -e "  ${GREEN}Passed:  $PASS${RESET}"
echo -e "  ${RED}Failed:  $FAIL${RESET}"
echo -e "  ${YELLOW}Skipped: $SKIP${RESET}"
echo -e "  Total:   $TOTAL"
echo ""

if [ ${#FAILURES[@]} -gt 0 ]; then
  echo -e "${BOLD}${RED}Failures:${RESET}"
  for f in "${FAILURES[@]}"; do
    echo -e "  ${RED}• $f${RESET}"
  done
  echo ""
  exit 1
fi

echo -e "${GREEN}${BOLD}All tests passed.${RESET}"
exit 0
