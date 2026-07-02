#!/usr/bin/env sh
set -eu

for command in \
  "deps.get --check-locked" \
  "deps.unlock --check-unused" \
  "format --check-formatted" \
  "credo --strict" \
  "compile --warnings-as-errors --force" \
  "deps.audit" \
  "test --seed 0"
do
  grep -F "\"$command\"" core/mix.exs >/dev/null || {
    echo "mix gate missing: $command" >&2
    exit 1
  }
  grep -F "\`$command\`" docs/guardrails-conformance.md >/dev/null || {
    echo "guardrails declaration missing: $command" >&2
    exit 1
  }
done

grep -F "ERL_COMPILER_OPTIONS=[deterministic]" docs/guardrails-conformance.md >/dev/null || {
  echo "guardrails declaration missing deterministic compiler option" >&2
  exit 1
}
