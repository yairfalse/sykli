#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
DRY_RUN=0

shift || true
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "[publish-elixir] error: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "Usage: scripts/publish-elixir.sh <version> [--dry-run]" >&2; exit 1; }

echo "[publish-elixir] package: sykli@$VERSION"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[publish-elixir] dry run: would run mix hex.publish from sdk/elixir"
  exit 0
fi

if [[ -z "${HEX_API_KEY:-}" ]]; then
  echo "[publish-elixir] error: HEX_API_KEY is required" >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/../sdk/elixir"
mix hex.publish --yes
