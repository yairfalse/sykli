#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() {
  printf '[check-version] %s\n' "$*"
}

die() {
  printf '[check-version] error: %s\n' "$*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$ROOT/$path" ]] || die "required file missing: $path"
}

extract_once() {
  local path="$1"
  local pattern="$2"
  require_file "$path"
  FILE_PATH="$ROOT/$path" PATTERN="$pattern" python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["FILE_PATH"])
pattern = os.environ["PATTERN"]
match = re.search(pattern, path.read_text(), flags=re.MULTILINE)
if not match:
    raise SystemExit(f"pattern not found in {path}")
print(match.group(1))
PY
}

require_file "VERSION"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  die "VERSION must be semver without a leading v, got '$VERSION'"
fi

declare -a CHECKS=(
  "core/mix.exs|@version\\s+\"([^\"]+)\""
  "sdk/elixir/mix.exs|version:\\s+\"([^\"]+)\""
  "sdk/rust/Cargo.toml|^version\\s*=\\s*\"([^\"]+)\""
  "sdk/python/pyproject.toml|^version\\s*=\\s*\"([^\"]+)\""
  "sdk/typescript/package.json|\"version\":\\s*\"([^\"]+)\""
  "sdk/typescript/package-lock.json|\"version\":\\s*\"([^\"]+)\""
)

FAILED=0

log "source of truth VERSION=$VERSION"

for check in "${CHECKS[@]}"; do
  path="${check%%|*}"
  pattern="${check#*|}"
  found="$(extract_once "$path" "$pattern")"
  if [[ "$found" == "$VERSION" ]]; then
    log "ok $path = $found"
  else
    printf '[check-version] mismatch %s: expected %s, found %s\n' "$path" "$VERSION" "$found" >&2
    FAILED=1
  fi
done

require_file "sdk/go/go.mod"
if grep -q '^module github.com/yairfalse/sykli/sdk/go$' "$ROOT/sdk/go/go.mod"; then
  log "ok sdk/go/go.mod uses submodule tag strategy: sdk/go/v$VERSION"
else
  printf '[check-version] mismatch sdk/go/go.mod: unexpected module path\n' >&2
  FAILED=1
fi

if [[ "$FAILED" -ne 0 ]]; then
  die "version consistency check failed"
fi

log "all package versions are in sync"
