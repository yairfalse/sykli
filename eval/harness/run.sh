#!/usr/bin/env bash
# ============================================================================
# Sykli Eval Harness — AI agent evaluation loop.
#
# For each case: gives Claude Code a task prompt → waits for implementation →
# rebuilds sykli → runs the oracle to validate → produces a JSON report.
#
# This evaluates whether Claude Code can correctly implement features
# against Sykli's codebase, validated by the oracle's ground-truth cases.
#
# Usage:
#   eval/harness/run.sh                    # run all eval cases
#   eval/harness/run.sh --case 001         # run one case
#   eval/harness/run.sh --dry-run          # show cases without running
#   eval/harness/run.sh --timeout 120      # per-case timeout (default: 120s)
#
# Requires:
#   - claude CLI (Claude Code)
#   - sykli binary (will be rebuilt after each case)
#   - jq
# ============================================================================

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
ORACLE="$REPO_ROOT/eval/oracle/run.sh"
CASES_DIR="$HARNESS_DIR/cases"
RESULTS_DIR="$REPO_ROOT/eval/results"
DEFAULT_TIMEOUT=120
TIMEOUT="$DEFAULT_TIMEOUT"
CASE_FILTER=""
DRY_RUN=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# --- Argument parsing ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      echo "Usage: eval/harness/run.sh [--case 001] [--timeout 120] [--dry-run]"
      exit 0 ;;
    --case) CASE_FILTER="$2"; shift 2 ;;
    --case=*) CASE_FILTER="${1#--case=}"; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#--timeout=}"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --- Pre-flight ---

if ! command -v claude &>/dev/null; then
  echo -e "${RED}Error: claude CLI not found${RESET}"
  echo "Install: https://claude.ai/code"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo -e "${RED}Error: jq not found${RESET}"
  exit 1
fi

# --- Load cases ---

cases=()
for f in "$CASES_DIR"/*.yaml "$CASES_DIR"/*.yml; do
  [[ -f "$f" ]] || continue
  cases+=("$f")
done

if [[ ${#cases[@]} -eq 0 ]]; then
  echo -e "${RED}No eval cases found in $CASES_DIR${RESET}"
  exit 1
fi

# Sort cases by filename
IFS=$'\n' cases=($(sort <<< "${cases[*]}")); unset IFS

printf "${BOLD}${CYAN}━━━ sykli eval harness ━━━${RESET}\n"
printf "${DIM}Cases: ${#cases[@]}${RESET}\n"
printf "${DIM}Timeout: ${TIMEOUT}s per case${RESET}\n\n"

if [[ "$DRY_RUN" == "true" ]]; then
  for case_file in "${cases[@]}"; do
    id=$(grep '^id:' "$case_file" | head -1 | sed 's/id: *//' | tr -d '"')
    desc=$(grep '^description:' "$case_file" | head -1 | sed 's/description: *//' | tr -d '"')
    oracle_case=$(grep '^oracle_case:' "$case_file" | head -1 | sed 's/oracle_case: *//' | tr -d '"')
    printf "  ${CYAN}%-12s${RESET} %s ${DIM}(oracle: %s)${RESET}\n" "$id" "$desc" "$oracle_case"
  done
  exit 0
fi

# --- Run cases ---

results="[]"
total=0
passed=0
failed=0

for case_file in "${cases[@]}"; do
  id=$(grep '^id:' "$case_file" | head -1 | sed 's/id: *//' | tr -d '"')
  desc=$(grep '^description:' "$case_file" | head -1 | sed 's/description: *//' | tr -d '"')
  oracle_case=$(grep '^oracle_case:' "$case_file" | head -1 | sed 's/oracle_case: *//' | tr -d '"')
  prompt=$(sed -n '/^task_prompt:/,/^[a-z]/{ /^task_prompt:/d; /^[a-z]/d; p; }' "$case_file" | sed 's/^  //')

  # Per-case timeout override
  case_timeout=$(grep '^timeout_secs:' "$case_file" | head -1 | sed 's/timeout_secs: *//' | tr -d '"')
  case_timeout="${case_timeout:-$TIMEOUT}"

  # Filter
  if [[ -n "$CASE_FILTER" && "$id" != *"$CASE_FILTER"* ]]; then
    continue
  fi

  total=$((total + 1))
  printf "${CYAN}▶${RESET} ${BOLD}%s${RESET} — %s\n" "$id" "$desc"

  start_s=$(date +%s)

  # Step 1: Create a git branch for this case
  branch="eval/$id"
  (cd "$REPO_ROOT" && git stash -q 2>/dev/null || true)
  (cd "$REPO_ROOT" && git checkout -qb "$branch" 2>/dev/null || git checkout -q "$branch" 2>/dev/null || true)

  # Step 2: Run Claude Code with the task prompt
  printf "  ${DIM}running claude...${RESET}\n"
  set +e
  claude_output=$(cd "$REPO_ROOT" && timeout "${case_timeout}s" claude --print --dangerously-skip-permissions "$prompt" 2>&1)
  claude_exit=$?
  set -e

  # Step 3: Rebuild sykli
  printf "  ${DIM}rebuilding sykli...${RESET}\n"
  (cd "$REPO_ROOT/core" && mix escript.build 2>&1 | tail -1)

  # Step 4: Run the oracle case
  printf "  ${DIM}running oracle case ${oracle_case}...${RESET}\n"
  set +e
  oracle_output=$("$ORACLE" --case "$oracle_case" 2>&1)
  oracle_exit=$?
  set -e

  elapsed=$(($(date +%s) - start_s))

  # Step 5: Record result
  if [[ "$oracle_exit" -eq 0 ]]; then
    printf "  ${GREEN}✓ PASS${RESET} ${DIM}(${elapsed}s)${RESET}\n\n"
    case_passed=true
    passed=$((passed + 1))
  else
    printf "  ${RED}✗ FAIL${RESET} ${DIM}(${elapsed}s)${RESET}\n"
    echo "$oracle_output" | grep -E "✗|fail" | head -5 | sed 's/^/    /'
    printf "\n"
    case_passed=false
    failed=$((failed + 1))
  fi

  # Step 6: Reset branch
  (cd "$REPO_ROOT" && git checkout -q - 2>/dev/null && git branch -qD "$branch" 2>/dev/null || true)
  (cd "$REPO_ROOT" && git stash pop -q 2>/dev/null || true)

  # Append to results JSON
  result=$(jq -n \
    --arg id "$id" \
    --arg desc "$desc" \
    --argjson passed "$case_passed" \
    --arg oracle_case "$oracle_case" \
    --argjson oracle_exit "$oracle_exit" \
    --argjson claude_exit "$claude_exit" \
    --argjson duration "$elapsed" \
    '{id: $id, description: $desc, passed: $passed, oracle_case: $oracle_case, oracle_exit_code: $oracle_exit, claude_exit_code: $claude_exit, duration_secs: $duration}')
  results=$(echo "$results" | jq ". + [$result]")
done

# --- Report ---

printf "${BOLD}━━━ Results ━━━${RESET}\n"
printf "  ${GREEN}Passed:  $passed${RESET}\n"
printf "  ${RED}Failed:  $failed${RESET}\n"
printf "  Total:   $total\n"

# Write JSON report
mkdir -p "$RESULTS_DIR"
report=$(jq -n \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson total "$total" \
  --argjson passed "$passed" \
  --argjson failed "$failed" \
  --argjson results "$results" \
  '{timestamp: $timestamp, total: $total, passed: $passed, failed: $failed, results: $results}')

echo "$report" | jq . > "$RESULTS_DIR/latest.json"
printf "\n${DIM}Report: eval/results/latest.json${RESET}\n"

[[ "$failed" -eq 0 ]] || exit 1
