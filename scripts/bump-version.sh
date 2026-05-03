#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: scripts/bump-version.sh <version> [--dry-run]

Updates VERSION plus every package manifest that carries the shared Sykli
release version. Go uses module-aware git tags, so sdk/go/go.mod is validated
but has no embedded package version to rewrite.
USAGE
}

log() {
  printf '[bump-version] %s\n' "$*"
}

die() {
  printf '[bump-version] error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
shift
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  die "version must be semver without a leading v, got '$VERSION'"
fi

require_file() {
  local path="$1"
  [[ -f "$ROOT/$path" ]] || die "required file missing: $path"
}

replace_once() {
  local path="$1"
  local pattern="$2"
  local replacement="$3"

  require_file "$path"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "would update $path"
    return
  fi

  FILE_PATH="$ROOT/$path" PATTERN="$pattern" REPLACEMENT="$replacement" python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["FILE_PATH"])
pattern = os.environ["PATTERN"]
replacement = os.environ["REPLACEMENT"]
text = path.read_text()
new_text, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
if count != 1:
    raise SystemExit(f"pattern did not match exactly once in {path}")
path.write_text(new_text)
PY
}

replace_all_checked() {
  local path="$1"
  local pattern="$2"
  local replacement="$3"
  local expected_count="$4"

  require_file "$path"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "would update $path"
    return
  fi

  FILE_PATH="$ROOT/$path" PATTERN="$pattern" REPLACEMENT="$replacement" EXPECTED_COUNT="$expected_count" python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["FILE_PATH"])
pattern = os.environ["PATTERN"]
replacement = os.environ["REPLACEMENT"]
expected = int(os.environ["EXPECTED_COUNT"])
text = path.read_text()
new_text, count = re.subn(pattern, replacement, text, count=expected, flags=re.MULTILINE)
if count != expected:
    raise SystemExit(f"expected {expected} replacements in {path}, got {count}")
path.write_text(new_text)
PY
}

require_file "core/mix.exs"
require_file "sdk/elixir/mix.exs"
require_file "sdk/rust/Cargo.toml"
require_file "sdk/python/pyproject.toml"
require_file "sdk/typescript/package.json"
require_file "sdk/typescript/package-lock.json"
require_file "sdk/go/go.mod"

log "target version: $VERSION"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "would update VERSION"
else
  printf '%s\n' "$VERSION" > "$ROOT/VERSION"
fi

replace_once "core/mix.exs" '(@version\s+")[^"]+(")' "\\g<1>$VERSION\\g<2>"
replace_once "sdk/elixir/mix.exs" '(version:\s+")[^"]+(")' "\\g<1>$VERSION\\g<2>"
replace_once "sdk/rust/Cargo.toml" '(^version\s*=\s*")[^"]+(")' "\\g<1>$VERSION\\g<2>"
replace_once "sdk/python/pyproject.toml" '(^version\s*=\s*")[^"]+(")' "\\g<1>$VERSION\\g<2>"
replace_once "sdk/typescript/package.json" '("version":\s*")[^"]+(")' "\\g<1>$VERSION\\g<2>"
replace_all_checked "sdk/typescript/package-lock.json" '("version":\s*")[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?(")' "\\g<1>$VERSION\\g<3>" 2

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry run complete; no files changed"
else
  "$ROOT/scripts/check-version.sh"
  log "version bump complete"
fi
