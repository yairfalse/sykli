#!/usr/bin/env bash
# ============================================================================
# Sykli Oracle — ground-truth validation against the live binary.
#
# Each numbered case encodes a system guarantee. When a case fails, it means
# Sykli's public contract is broken. The oracle never reads source code.
#
# Usage:
#   eval/oracle/run.sh                    # run all cases
#   eval/oracle/run.sh --case 001         # run one case
#   eval/oracle/run.sh --category pipeline # run a category
#   eval/oracle/run.sh --verbose          # show command output on failure
#
# Requires:
#   - sykli binary (SYKLI_BIN or core/sykli)
#   - jq
#   - Elixir (for SDK fixture execution)
# ============================================================================

set -euo pipefail

# --- Configuration ---

SYKLI_BIN="${SYKLI_BIN:-$(cd "$(dirname "$0")/../../core" && pwd)/sykli}"
ORACLE_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="$ORACLE_DIR/fixtures"
VERBOSE="${VERBOSE:-false}"
CASE_FILTER=""
CATEGORY_FILTER=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# Counters
PASSED=0
FAILED=0
SKIPPED=0
FAILURES=""

# --- Argument parsing ---

usage() {
  echo "Usage: eval/oracle/run.sh [--case 001] [--category pipeline] [--verbose] [--help]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --case)
      if [[ $# -lt 2 || "$2" == --* ]]; then echo "Error: --case requires an argument" >&2; exit 1; fi
      CASE_FILTER="$2"; shift 2 ;;
    --case=*) CASE_FILTER="${1#--case=}"; shift ;;
    --category)
      if [[ $# -lt 2 || "$2" == --* ]]; then echo "Error: --category requires an argument" >&2; exit 1; fi
      CATEGORY_FILTER="$2"; shift 2 ;;
    --category=*) CATEGORY_FILTER="${1#--category=}"; shift ;;
    --verbose) VERBOSE=true; shift ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

# --- Helpers ---

tmp_workdir() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/sykli-oracle-XXXXXX")
  echo "$dir"
}

# Create a minimal sykli.exs fixture in a temp dir
make_pipeline() {
  local dir="$1"
  local fixture="$2"
  cp "$FIXTURES_DIR/$fixture" "$dir/sykli.exs"
}


run_sykli() {
  local dir="$1"
  shift
  (cd "$dir" && "$SYKLI_BIN" "$@" 2>&1)
}

# Settlement: wait for async effects (file writes, etc.)
settle() {
  sleep "${1:-0.2}"
}

# --- Test framework ---

current_case=""
case_desc=""

begin_case() {
  current_case="$1"
  case_desc="$2"

  # Filter
  if [[ -n "$CASE_FILTER" && "$current_case" != "$CASE_FILTER" ]]; then
    return 1
  fi
  if [[ -n "$CATEGORY_FILTER" ]]; then
    local cat
    cat=$(echo "$case_desc" | cut -d: -f1 | tr '[:upper:]' '[:lower:]')
    if [[ "$cat" != "$CATEGORY_FILTER" ]]; then
      return 1
    fi
  fi
  return 0
}

pass() {
  printf "  ${GREEN}✓ %-8s${RESET} %s ${DIM}(%dms)${RESET}\n" "$current_case" "$case_desc" "$1"
  PASSED=$((PASSED + 1))
}

fail() {
  local reason="$1"
  printf "  ${RED}✗ %-8s${RESET} %s\n" "$current_case" "$case_desc"
  printf "    ${DIM}%s${RESET}\n" "$reason"
  FAILED=$((FAILED + 1))
  FAILURES="$FAILURES\n  ${RED}• $current_case: $reason${RESET}"
  if [[ "$VERBOSE" == "true" && -n "${LAST_OUTPUT:-}" ]]; then
    printf "    ${DIM}--- output ---${RESET}\n"
    echo "$LAST_OUTPUT" | head -20 | sed 's/^/    /'
    printf "    ${DIM}--- end ---${RESET}\n"
  fi
}

skip() {
  printf "  ${YELLOW}○ %-8s${RESET} %s ${DIM}(skipped: %s)${RESET}\n" "$current_case" "$case_desc" "$1"
  SKIPPED=$((SKIPPED + 1))
}

assert_exit() {
  local expected="$1" actual="$2" context="${3:-}"
  if [[ "$actual" -ne "$expected" ]]; then
    fail "exit code: expected=$expected actual=$actual${context:+ ($context)}"
    return 1
  fi
  return 0
}

assert_contains() {
  local haystack="$1" needle="$2" context="${3:-}"
  if ! echo "$haystack" | grep -qE "$needle"; then
    fail "expected output to contain '$needle'${context:+ ($context)}"
    return 1
  fi
  return 0
}

assert_json_field() {
  local json="$1" field="$2" expected="$3" context="${4:-}"
  local actual
  actual=$(echo "$json" | jq -r "$field" 2>/dev/null)
  if [[ "$actual" != "$expected" ]]; then
    fail "JSON $field: expected='$expected' actual='$actual'${context:+ ($context)}"
    return 1
  fi
  return 0
}

assert_file_exists() {
  local path="$1" context="${2:-}"
  if [[ ! -f "$path" ]]; then
    fail "file not found: $path${context:+ ($context)}"
    return 1
  fi
  return 0
}

assert_valid_json() {
  local path="$1" context="${2:-}"
  if ! jq empty "$path" 2>/dev/null; then
    fail "invalid JSON: $path${context:+ ($context)}"
    return 1
  fi
  return 0
}

# --- Pre-flight ---

if [[ ! -x "$SYKLI_BIN" ]]; then
  echo -e "${RED}Error: sykli binary not found at $SYKLI_BIN${RESET}"
  echo "Build it: cd core && mix escript.build"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo -e "${RED}Error: jq not found${RESET}"
  exit 1
fi

printf "${BOLD}${CYAN}━━━ sykli oracle ━━━${RESET}\n"
printf "${DIM}Binary: $SYKLI_BIN${RESET}\n\n"

# ============================================================================
# PIPELINE EXECUTION (001-005)
# ============================================================================

printf "${BOLD}Pipeline Execution${RESET}\n"

# --- case_001: basic pipeline passes ---
if begin_case "001" "Pipeline: basic pass"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "pass.exs"
  start_ms=$(($(date +%s) * 1000))
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  elapsed=$(( $(date +%s) * 1000 - start_ms ))
  if assert_exit 0 "$exit_code"; then
    pass "$elapsed"
  fi
  rm -rf "$dir"
fi

# --- case_002: failing task exits non-zero ---
if begin_case "002" "Pipeline: failing task exits non-zero"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "fail.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 1 "$exit_code"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# --- case_003: occurrence.json written after run ---
if begin_case "003" "Pipeline: occurrence.json written"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "pass.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/occurrence.json"; then
    if assert_valid_json "$dir/.sykli/occurrence.json"; then
      json=$(cat "$dir/.sykli/occurrence.json")
      if assert_json_field "$json" ".protocol_version" "1.0" "occurrence protocol version"; then
        pass 0
      fi
    fi
  fi
  rm -rf "$dir"
fi

# --- case_004: validate command exits 0 for valid pipeline ---
if begin_case "004" "Pipeline: validate accepts valid pipeline"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "pass.exs"
  LAST_OUTPUT=$(run_sykli "$dir" validate --json 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# --- case_005: multi-task DAG executes in correct order ---
if begin_case "005" "Pipeline: DAG dependency ordering"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "dag.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "passed"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# ============================================================================
# AI CONTEXT (006-010)
# ============================================================================

printf "\n${BOLD}AI Context${RESET}\n"

# --- case_006: occurrence has error block for failed run ---
if begin_case "006" "AI Context: error block for failed run"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "fail.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/occurrence.json"; then
    json=$(cat "$dir/.sykli/occurrence.json")
    error=$(echo "$json" | jq -r '.error' 2>/dev/null)
    if [[ "$error" != "null" && -n "$error" ]]; then
      pass 0
    else
      fail "occurrence.json missing error block for failed run"
    fi
  fi
  rm -rf "$dir"
fi

# --- case_007: occurrence has history block with steps ---
if begin_case "007" "AI Context: history block with steps"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "pass.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/occurrence.json"; then
    json=$(cat "$dir/.sykli/occurrence.json")
    steps=$(echo "$json" | jq '.history.steps | length' 2>/dev/null)
    if [[ "$steps" -gt 0 ]]; then
      pass 0
    else
      fail "occurrence.json history.steps is empty"
    fi
  fi
  rm -rf "$dir"
fi

# --- case_008: occurrence has git context ---
if begin_case "008" "AI Context: git context in occurrence"; then
  dir=$(tmp_workdir)
  # Initialize a git repo so git context is available
  (cd "$dir" && git init -q && git -c user.name="Oracle" -c user.email="oracle@test" commit --allow-empty -m "init" -q)
  make_pipeline "$dir" "pass.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/occurrence.json"; then
    json=$(cat "$dir/.sykli/occurrence.json")
    sha=$(echo "$json" | jq -r '.data.git.sha' 2>/dev/null)
    if [[ -n "$sha" && "$sha" != "null" ]]; then
      pass 0
    else
      fail "occurrence.json missing data.git.sha"
    fi
  fi
  rm -rf "$dir"
fi

# --- case_009: explain command produces output ---
if begin_case "009" "AI Context: explain command works"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "pass.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  LAST_OUTPUT=$(run_sykli "$dir" explain 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "passed|success|run"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# --- case_010: context command generates context.json ---
if begin_case "010" "AI Context: context command writes context.json"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "pass.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  run_sykli "$dir" context >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/context.json"; then
    if assert_valid_json "$dir/.sykli/context.json"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# ============================================================================
# CACHING (011)
# ============================================================================

printf "\n${BOLD}Caching${RESET}\n"

# --- case_011: second run uses cache ---
if begin_case "011" "Caching: second run hits cache"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "cached.exs"
  # First run
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  # Second run — should cache
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "CACHED|cached"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# ============================================================================
# SUPPLY CHAIN (014-016)
# ============================================================================

printf "\n${BOLD}Supply Chain${RESET}\n"

# --- case_014: attestation.json written for passing run with outputs ---
if begin_case "014" "Supply Chain: attestation.json for passing run"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "with_outputs.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/attestation.json"; then
    if assert_valid_json "$dir/.sykli/attestation.json"; then
      json=$(cat "$dir/.sykli/attestation.json")
      if assert_json_field "$json" ".payloadType" "application/vnd.in-toto+json" "DSSE payload type"; then
        pass 0
      fi
    fi
  fi
  rm -rf "$dir"
fi

# --- case_015: attestation payload is valid SLSA ---
if begin_case "015" "Supply Chain: SLSA v1 provenance in payload"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "with_outputs.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/attestation.json"; then
    # Decode the DSSE payload
    payload=$(cat "$dir/.sykli/attestation.json" | jq -r '.payload' 2>/dev/null)
    decoded=$(echo "$payload" | base64 --decode 2>/dev/null || echo "$payload" | base64 -D 2>/dev/null) || decoded=""
    if [[ -n "$decoded" ]]; then
      stmt_type=$(echo "$decoded" | jq -r '._type' 2>/dev/null)
      if [[ "$stmt_type" == "https://in-toto.io/Statement/v1" ]]; then
        pred_type=$(echo "$decoded" | jq -r '.predicateType' 2>/dev/null)
        if assert_json_field "$decoded" ".predicateType" "https://slsa.dev/provenance/v1" "SLSA predicate type"; then
          pass 0
        fi
      else
        fail "attestation _type is '$stmt_type', expected in-toto Statement v1"
      fi
    else
      fail "could not base64-decode attestation payload"
    fi
  fi
  rm -rf "$dir"
fi

# --- case_016: failed run still generates attestation ---
if begin_case "016" "Supply Chain: attestation for failed run"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "fail.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/attestation.json"; then
    if assert_valid_json "$dir/.sykli/attestation.json"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# ============================================================================
# VALIDATION (017-019)
# ============================================================================

printf "\n${BOLD}Validation${RESET}\n"

# --- case_017: cycle detection ---
if begin_case "017" "Validation: cycle in DAG rejected"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "cycle.exs"
  LAST_OUTPUT=$(run_sykli "$dir" validate 2>&1) && exit_code=0 || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    if assert_contains "$LAST_OUTPUT" "cycle|circular|Cycle"; then
      pass 0
    fi
  else
    fail "validate should reject cyclic DAG"
  fi
  rm -rf "$dir"
fi

# --- case_018: no SDK file detected ---
if begin_case "018" "Validation: no SDK file exits with error"; then
  dir=$(tmp_workdir)
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    if assert_contains "$LAST_OUTPUT" "No sykli file|no_sdk_file|not found"; then
      pass 0
    fi
  else
    fail "should fail when no sykli.* file exists"
  fi
  rm -rf "$dir"
fi

# --- case_019: empty task graph ---
if begin_case "019" "Validation: empty task graph"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "empty.exs"
  LAST_OUTPUT=$(run_sykli "$dir" validate --json 2>&1) && exit_code=0 || exit_code=$?
  # Empty graph should pass validation (valid JSON, zero tasks)
  if assert_exit 0 "$exit_code"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# ============================================================================
# CLI COMMANDS (020-022)
# ============================================================================

printf "\n${BOLD}CLI Commands${RESET}\n"

# --- case_020: history command ---
if begin_case "020" "CLI: history command"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "pass.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  LAST_OUTPUT=$(run_sykli "$dir" history 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# --- case_021: graph command produces mermaid ---
if begin_case "021" "CLI: graph command produces mermaid"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "dag.exs"
  LAST_OUTPUT=$(run_sykli "$dir" graph 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "graph|flowchart|-->"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# --- case_022: --help exits 0 ---
if begin_case "022" "CLI: --help exits 0"; then
  dir=$(tmp_workdir)
  LAST_OUTPUT=$(cd "$dir" && "$SYKLI_BIN" --help 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "sykli|SYKLI|Usage|usage"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# ============================================================================
# ADVERSARIAL INPUTS (023-026)
# ============================================================================

printf "\n${BOLD}Adversarial Inputs${RESET}\n"

# --- case_023: unicode task names ---
if begin_case "023" "Adversarial: unicode task names execute"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "unicode_name.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "passed"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# --- case_024: shell special characters in command ---
if begin_case "024" "Adversarial: shell special chars in command"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "shell_special.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "done"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# --- case_025: task producing 5000 lines of output ---
if begin_case "025" "Adversarial: large output (5000 lines) doesn't crash"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "big_output.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# --- case_026: duplicate task names ---
if begin_case "026" "Adversarial: duplicate task names handled"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "duplicate_names.exs"
  LAST_OUTPUT=$(run_sykli "$dir" validate --json 2>&1) && exit_code=0 || exit_code=$?
  # Must not crash (signal death = exit >= 128)
  if [[ "$exit_code" -lt 128 ]]; then
    pass 0
  else
    fail "process crashed with signal (exit code $exit_code)"
  fi
  rm -rf "$dir"
fi

# ============================================================================
# DAG SCALE (027-029)
# ============================================================================

printf "\n${BOLD}DAG Scale${RESET}\n"

# --- case_027: 30-level deep chain ---
if begin_case "027" "Scale: 30-level deep DAG chain completes"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "deep_dag.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "30 passed"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# --- case_028: 50 parallel tasks ---
if begin_case "028" "Scale: 50 parallel tasks at one level"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "wide_dag.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "50 passed"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# --- case_029: task with no command field ---
if begin_case "029" "Scale: task with no command doesn't crash"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "no_command.exs"
  # Should either skip gracefully or produce clear error — must not crash
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  # Must not crash (signal death = exit >= 128)
  if [[ "$exit_code" -lt 128 ]]; then
    pass 0
  else
    fail "process crashed with signal (exit code $exit_code)"
  fi
  rm -rf "$dir"
fi

# ============================================================================
# EXECUTION SEMANTICS (030-033)
# ============================================================================

printf "\n${BOLD}Execution Semantics${RESET}\n"

# --- case_030: continue-on-failure runs independent tasks ---
if begin_case "030" "Semantics: --continue-on-failure runs independent tasks"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "continue_on_fail.exs"
  LAST_OUTPUT=$(run_sykli "$dir" --continue-on-failure 2>&1) && exit_code=0 || exit_code=$?
  # Pipeline should fail overall but "independent" should still run
  if [[ "$exit_code" -eq 0 ]]; then
    fail "pipeline should fail overall even with --continue-on-failure"
  elif assert_contains "$LAST_OUTPUT" "still-ran"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# --- case_031: blocked downstream doesn't execute ---
if begin_case "031" "Semantics: blocked task skipped when dependency fails"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "blocked_downstream.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    # "deploy" should NOT have run
    if ! echo "$LAST_OUTPUT" | grep -q "echo deploy"; then
      pass 0
    else
      fail "blocked task 'deploy' should not have executed"
    fi
  else
    fail "pipeline should fail when build fails"
  fi
  rm -rf "$dir"
fi

# --- case_032: condition skips task ---
if begin_case "032" "Semantics: when condition skips non-matching task"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "condition_skip.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "skipped|SKIPPED"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# --- case_033: matrix expansion creates N tasks ---
if begin_case "033" "Semantics: matrix expands to 3 tasks"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "matrix.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "3 passed"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# ============================================================================
# SECURITY (034-036)
# ============================================================================

printf "\n${BOLD}Security${RESET}\n"

# --- case_034: secrets masked in occurrence.json ---
if begin_case "034" "Security: secrets masked in occurrence.json"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "secret_env.exs"
  # Set a secret env var and run
  SYKLI_TEST_SECRET_TOKEN="super-secret-value-12345" run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/occurrence.json"; then
    json=$(cat "$dir/.sykli/occurrence.json")
    # The actual secret value must NOT appear in the occurrence
    if echo "$json" | grep -q "super-secret-value-12345"; then
      fail "secret value leaked into occurrence.json"
    else
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# --- case_035: occurrence has summary counts ---
if begin_case "035" "Security: occurrence summary has correct counts"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "dag.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/occurrence.json"; then
    json=$(cat "$dir/.sykli/occurrence.json")
    passed_count=$(echo "$json" | jq '.data.summary.passed' 2>/dev/null)
    if [[ "$passed_count" == "3" ]]; then
      pass 0
    else
      fail "expected summary.passed=3, got $passed_count"
    fi
  fi
  rm -rf "$dir"
fi

# --- case_036: occurrence has correct type for failing run ---
if begin_case "036" "Security: occurrence type is ci.run.failed for failures"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "fail.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/occurrence.json"; then
    json=$(cat "$dir/.sykli/occurrence.json")
    if assert_json_field "$json" ".type" "ci.run.failed"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# ============================================================================
# CACHE CORRECTNESS (037-039)
# ============================================================================

printf "\n${BOLD}Cache Correctness${RESET}\n"

# --- case_037: changing command busts cache ---
if begin_case "037" "Cache: command change invalidates cache"; then
  dir=$(tmp_workdir)
  # First run with cached.exs (command: echo cached)
  make_pipeline "$dir" "cached.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  # Second run with cache_bust.exs (command: echo changed-command, same inputs)
  make_pipeline "$dir" "cache_bust.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    # Should NOT be cached — command changed
    if echo "$LAST_OUTPUT" | grep -q "command changed"; then
      pass 0
    elif ! echo "$LAST_OUTPUT" | grep -qi "cached"; then
      pass 0
    else
      fail "task should not be cached after command change"
    fi
  fi
  rm -rf "$dir"
fi

# --- case_038: occurrence written to per-run archive ---
if begin_case "038" "Cache: per-run occurrence JSON archived"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "pass.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  archive_dir="$dir/.sykli/occurrences_json"
  if [[ -d "$archive_dir" ]]; then
    count=$(ls "$archive_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -ge 1 ]]; then
      pass 0
    else
      fail "expected at least 1 archived occurrence JSON, got $count"
    fi
  else
    fail "occurrences_json directory not created"
  fi
  rm -rf "$dir"
fi

# --- case_039: validate --json produces valid JSON ---
if begin_case "039" "Cache: validate --json is parseable JSON"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "dag.exs"
  LAST_OUTPUT=$(run_sykli "$dir" validate --json 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if echo "$LAST_OUTPUT" | jq empty 2>/dev/null; then
      pass 0
    else
      fail "validate --json output is not valid JSON"
    fi
  fi
  rm -rf "$dir"
fi

# ============================================================================
# ATTESTATION DEEP (040-042)
# ============================================================================

printf "\n${BOLD}Attestation Deep${RESET}\n"

# --- case_040: attestation has subjects with SHA256 digests ---
if begin_case "040" "Attestation: subjects have sha256 digests"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "with_outputs.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/attestation.json"; then
    payload=$(cat "$dir/.sykli/attestation.json" | jq -r '.payload' 2>/dev/null)
    decoded=$(echo "$payload" | base64 --decode 2>/dev/null || echo "$payload" | base64 -D 2>/dev/null) || decoded=""
    if [[ -n "$decoded" ]]; then
      subject_count=$(echo "$decoded" | jq '.subject | length' 2>/dev/null)
      if [[ "$subject_count" -gt 0 ]]; then
        digest=$(echo "$decoded" | jq -r '.subject[0].digest.sha256' 2>/dev/null)
        if [[ -n "$digest" && "$digest" != "null" && ${#digest} -eq 64 ]]; then
          pass 0
        else
          fail "subject digest is not a 64-char SHA256: '$digest'"
        fi
      else
        fail "attestation has 0 subjects"
      fi
    else
      fail "could not decode attestation payload"
    fi
  fi
  rm -rf "$dir"
fi

# --- case_041: attestation builder has sykli version ---
if begin_case "041" "Attestation: builder includes sykli version"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "with_outputs.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/attestation.json"; then
    payload=$(cat "$dir/.sykli/attestation.json" | jq -r '.payload' 2>/dev/null)
    decoded=$(echo "$payload" | base64 --decode 2>/dev/null || echo "$payload" | base64 -D 2>/dev/null) || decoded=""
    if [[ -n "$decoded" ]]; then
      builder_id=$(echo "$decoded" | jq -r '.predicate.runDetails.builder.id' 2>/dev/null)
      if [[ "$builder_id" == "https://sykli.dev/builder/v1" ]]; then
        version=$(echo "$decoded" | jq -r '.predicate.runDetails.builder.version.sykli' 2>/dev/null)
        if [[ -n "$version" && "$version" != "null" ]]; then
          pass 0
        else
          fail "builder.version.sykli is missing"
        fi
      else
        fail "builder.id expected 'https://sykli.dev/builder/v1', got '$builder_id'"
      fi
    else
      fail "could not decode attestation payload"
    fi
  fi
  rm -rf "$dir"
fi

# --- case_042: per-task attestation written ---
if begin_case "042" "Attestation: per-task attestation file written"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "with_outputs.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  att_dir="$dir/.sykli/attestations"
  if [[ -d "$att_dir" ]]; then
    count=$(ls "$att_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -ge 1 ]]; then
      # Verify the per-task file is valid JSON
      first=$(ls "$att_dir"/*.json | head -1)
      if jq empty "$first" 2>/dev/null; then
        pass 0
      else
        fail "per-task attestation is not valid JSON"
      fi
    else
      fail "expected per-task attestation files, got 0"
    fi
  else
    fail "attestations/ directory not created"
  fi
  rm -rf "$dir"
fi

# ============================================================================
# COMMAND EDGE CASES (043-048)
# ============================================================================

printf "\n${BOLD}Command Edge Cases${RESET}\n"

# --- case_043: pipe in command works ---
if begin_case "043" "Command: pipe works (echo | grep)"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "pipe_command.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# --- case_044: exit code 2 is still failure ---
if begin_case "044" "Command: exit code 2 is failure (not just 1)"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "exit_code_2.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    pass 0
  else
    fail "exit code 2 should be treated as failure"
  fi
  rm -rf "$dir"
fi

# --- case_045: stderr doesn't break execution ---
if begin_case "045" "Command: stderr output doesn't prevent success"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "stderr_output.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# --- case_046: JSON in task output doesn't corrupt occurrence ---
if begin_case "046" "Command: JSON in task output doesn't corrupt occurrence"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "json_in_output.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/occurrence.json"; then
    if assert_valid_json "$dir/.sykli/occurrence.json"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# --- case_047: task name with slash works (log path sanitization) ---
if begin_case "047" "Command: task name with slash (sdk/go) works"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "slash_name.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    # Check occurrence is valid even with slash in name
    run_sykli "$dir" >/dev/null 2>&1 || true
    settle
    if assert_file_exists "$dir/.sykli/occurrence.json"; then
      if assert_valid_json "$dir/.sykli/occurrence.json"; then
        pass 0
      fi
    fi
  fi
  rm -rf "$dir"
fi

# --- case_048: 200-char task name doesn't crash ---
if begin_case "048" "Command: 200-char task name doesn't crash"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "long_name.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# ============================================================================
# STRUCTURAL CORRECTNESS (049-055)
# ============================================================================

printf "\n${BOLD}Structural Correctness${RESET}\n"

# --- case_049: diamond DAG (join after split) ---
if begin_case "049" "Structure: diamond DAG (root→left+right→join)"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "diamond_dag.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if assert_contains "$LAST_OUTPUT" "4 passed"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# --- case_050: duration_ms is non-zero for real task ---
if begin_case "050" "Structure: duration_ms is non-zero in occurrence"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "slow_task.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/occurrence.json"; then
    json=$(cat "$dir/.sykli/occurrence.json")
    duration=$(echo "$json" | jq '.history.duration_ms' 2>/dev/null)
    if [[ "$duration" -gt 500 ]]; then
      pass 0
    else
      fail "duration_ms should be >500 for a 1s sleep task, got $duration"
    fi
  fi
  rm -rf "$dir"
fi

# --- case_051: occurrence reflects the LAST run, not a stale one ---
if begin_case "051" "Structure: occurrence.json reflects last run"; then
  dir=$(tmp_workdir)
  # First run: passing
  make_pipeline "$dir" "pass.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  # Second run: failing
  make_pipeline "$dir" "fail.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/occurrence.json"; then
    json=$(cat "$dir/.sykli/occurrence.json")
    outcome=$(echo "$json" | jq -r '.outcome' 2>/dev/null)
    if [[ "$outcome" == "failure" ]]; then
      pass 0
    else
      fail "occurrence should reflect last (failing) run, got outcome=$outcome"
    fi
  fi
  rm -rf "$dir"
fi

# --- case_052: explain --json produces valid JSON ---
if begin_case "052" "Structure: explain --json is valid JSON"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "pass.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  LAST_OUTPUT=$(run_sykli "$dir" explain --json 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    if echo "$LAST_OUTPUT" | jq empty 2>/dev/null; then
      pass 0
    else
      fail "explain --json is not valid JSON"
    fi
  fi
  rm -rf "$dir"
fi

# --- case_053: report command after run ---
if begin_case "053" "Structure: report command works after run"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "pass.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  LAST_OUTPUT=$(run_sykli "$dir" report 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# --- case_054: cache stats command works ---
if begin_case "054" "Structure: cache stats command works"; then
  dir=$(tmp_workdir)
  LAST_OUTPUT=$(run_sykli "$dir" cache stats 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# --- case_055: multiline output captured in occurrence ---
if begin_case "055" "Structure: multiline output doesn't corrupt occurrence"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "multiline_output.exs"
  run_sykli "$dir" >/dev/null 2>&1 || true
  settle
  if assert_file_exists "$dir/.sykli/occurrence.json"; then
    if assert_valid_json "$dir/.sykli/occurrence.json"; then
      pass 0
    fi
  fi
  rm -rf "$dir"
fi

# ============================================================================
# CONCURRENT RUNS (056-057)
# ============================================================================

printf "\n${BOLD}Concurrent Runs${RESET}\n"

# --- case_056: two concurrent runs both complete ---
if begin_case "056" "Concurrent: two parallel runs both complete"; then
  dir1=$(tmp_workdir)
  dir2=$(tmp_workdir)
  make_pipeline "$dir1" "pass.exs"
  make_pipeline "$dir2" "dag.exs"

  # Run both in background
  (run_sykli "$dir1" >/dev/null 2>&1) &
  pid1=$!
  (run_sykli "$dir2" >/dev/null 2>&1) &
  pid2=$!

  wait $pid1 && exit1=0 || exit1=$?
  wait $pid2 && exit2=0 || exit2=$?

  if [[ "$exit1" -eq 0 && "$exit2" -eq 0 ]]; then
    # Both should have produced occurrence.json
    settle
    if [[ -f "$dir1/.sykli/occurrence.json" && -f "$dir2/.sykli/occurrence.json" ]]; then
      pass 0
    else
      fail "one or both runs missing occurrence.json"
    fi
  else
    fail "concurrent runs failed: exit1=$exit1 exit2=$exit2"
  fi
  rm -rf "$dir1" "$dir2"
fi

# --- case_057: env vars don't leak between tasks ---
if begin_case "057" "Concurrent: env vars set in task config"; then
  dir=$(tmp_workdir)
  make_pipeline "$dir" "env_vars.exs"
  LAST_OUTPUT=$(run_sykli "$dir" 2>&1) && exit_code=0 || exit_code=$?
  if assert_exit 0 "$exit_code"; then
    pass 0
  fi
  rm -rf "$dir"
fi

# ============================================================================
# Summary
# ============================================================================

printf "\n${BOLD}━━━ Results ━━━${RESET}\n"
printf "  ${GREEN}Passed:  $PASSED${RESET}\n"
printf "  ${RED}Failed:  $FAILED${RESET}\n"
if [[ "$SKIPPED" -gt 0 ]]; then
  printf "  ${YELLOW}Skipped: $SKIPPED${RESET}\n"
fi
printf "  Total:   $((PASSED + FAILED + SKIPPED))\n"

if [[ "$FAILED" -gt 0 ]]; then
  printf "\n${BOLD}${RED}Failures:${RESET}"
  printf "$FAILURES\n"
  exit 1
fi
