#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
DRY_RUN=0

shift || true
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "[publish-ts] error: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "Usage: scripts/publish-ts.sh <version> [--dry-run]" >&2; exit 1; }

echo "[publish-ts] package: sykli@$VERSION"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[publish-ts] dry run: would run npm publish from sdk/typescript"
  exit 0
fi

if [[ -z "${NPM_TOKEN:-}" ]]; then
  echo "[publish-ts] error: NPM_TOKEN is required" >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/../sdk/typescript"

# Feed the token to npm via a throwaway userconfig. The ${NPM_TOKEN}
# placeholder is expanded by npm at run time, so the token itself is
# never written to disk.
npmrc="$(mktemp)"
trap 'rm -f "$npmrc"' EXIT
# shellcheck disable=SC2016
echo '//registry.npmjs.org/:_authToken=${NPM_TOKEN}' > "$npmrc"

NPM_CONFIG_USERCONFIG="$npmrc" npm publish
