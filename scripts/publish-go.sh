#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
DRY_RUN=0

shift || true
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "[publish-go] error: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "Usage: scripts/publish-go.sh <version> [--dry-run]" >&2; exit 1; }
TAG="sdk/go/v$VERSION"

echo "[publish-go] Go modules publish through git tags"
echo "[publish-go] module: github.com/yairfalse/sykli/sdk/go"
echo "[publish-go] tag: $TAG"

if ! grep -q '^module github.com/yairfalse/sykli/sdk/go$' "$ROOT/sdk/go/go.mod"; then
  echo "[publish-go] error: sdk/go/go.mod has unexpected module path" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[publish-go] dry run: would create/push $TAG if missing"
  exit 0
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "[publish-go] tag already exists locally: $TAG"
else
  git tag -a "$TAG" -m "$TAG"
fi

git push origin "$TAG"
