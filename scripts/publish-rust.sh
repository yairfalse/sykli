#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
DRY_RUN=0

shift || true
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "[publish-rust] error: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "Usage: scripts/publish-rust.sh <version> [--dry-run]" >&2; exit 1; }

echo "[publish-rust] package: sykli@$VERSION"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[publish-rust] dry run: would run cargo publish from sdk/rust"
  exit 0
fi

if [[ -z "${CARGO_REGISTRY_TOKEN:-}" ]]; then
  echo "[publish-rust] error: CARGO_REGISTRY_TOKEN is required" >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/../sdk/rust"
cargo publish
