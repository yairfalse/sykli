#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh <version> [--dry-run] [--publish]

Runs the full release gate, bumps package versions from the root VERSION source,
commits release metadata, creates a git tag, and optionally publishes SDKs.
USAGE
}

log() {
  printf '\n[release] %s\n' "$*"
}

die() {
  printf '[release] error: %s\n' "$*" >&2
  exit 1
}

run() {
  printf '[release] + %s\n' "$*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
shift
DRY_RUN=0
PUBLISH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --publish) PUBLISH=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  die "version must be semver without a leading v, got '$VERSION'"
fi

cd "$ROOT"

log "release v$VERSION"

if [[ -n "$(git status --porcelain)" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry run: actual release would fail because the working tree is not clean"
  else
    die "working tree is not clean"
  fi
fi

log "fetching tags"
run git fetch --tags

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry run: actual release would fail because tag already exists: v$VERSION"
  else
    die "tag already exists: v$VERSION"
  fi
fi

log "checking version consistency before bump"
run "$ROOT/scripts/check-version.sh"

log "bumping versions"
run "$ROOT/scripts/bump-version.sh" "$VERSION"

log "checking version consistency after bump"
run "$ROOT/scripts/check-version.sh"

log "running core tests"
run bash -lc 'cd core && mix test'

log "running SDK tests"
run bash -lc 'cd sdk/go && go test ./...'
run bash -lc 'cd sdk/rust && cargo test'
run bash -lc 'cd sdk/typescript && npm test'
run bash -lc 'cd sdk/python && python3 -m pytest'
run bash -lc 'cd sdk/elixir && mix test'

log "running cross-SDK conformance"
run "$ROOT/tests/conformance/run.sh"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "would commit release: v$VERSION"
  log "would tag v$VERSION"
else
  git add VERSION core/mix.exs sdk/elixir/mix.exs sdk/rust/Cargo.toml sdk/python/pyproject.toml sdk/typescript/package.json sdk/typescript/package-lock.json
  if git diff --cached --quiet; then
    log "no version files changed; release commit is not needed"
  else
    git commit -m "release: v$VERSION"
  fi
  git tag -a "v$VERSION" -m "v$VERSION"
fi

if [[ "$PUBLISH" -eq 1 ]]; then
  log "publishing SDKs"
  publish_args=()
  if [[ "$DRY_RUN" -eq 1 ]]; then
    publish_args+=(--dry-run)
  fi
  "$ROOT/scripts/publish-all.sh" "$VERSION" "${publish_args[@]}"
fi

log "release preparation complete"
