#!/usr/bin/env bash
set -euo pipefail

# Bump version across all SDKs atomically.
#
# Usage:
#   ./scripts/bump-version.sh 0.5.0
#   ./scripts/bump-version.sh 0.5.0 --commit   # also git commit
#   ./scripts/bump-version.sh 0.5.0 --dry-run   # show what would change

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version> [--commit] [--dry-run]"
  echo "Example: $0 0.5.0 --commit"
  exit 1
fi

NEW_VERSION="$1"
shift

COMMIT=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --commit) COMMIT=true ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# Validate version format (semver without v prefix)
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be semver (e.g. 0.5.0), got: $NEW_VERSION"
  exit 1
fi

echo "Bumping to $NEW_VERSION"
echo ""

bump_file() {
  local file="$1"
  local pattern="$2"
  local filepath="$ROOT/$file"

  if [[ ! -f "$filepath" ]]; then
    echo "  SKIP  $file (not found)"
    return
  fi

  local old
  old=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$filepath" | head -1)

  if [[ "$DRY_RUN" == true ]]; then
    echo "  WOULD $file: $old → $NEW_VERSION"
  else
    sed -i '' -E "$pattern" "$filepath"
    echo "  OK    $file: $old → $NEW_VERSION"
  fi
}

bump_file "core/mix.exs" \
  's/@version "[0-9]+\.[0-9]+\.[0-9]+"/@version "'"$NEW_VERSION"'"/'

bump_file "sdk/elixir/mix.exs" \
  's/version: "[0-9]+\.[0-9]+\.[0-9]+"/version: "'"$NEW_VERSION"'"/'

bump_file "sdk/typescript/package.json" \
  's/"version": "[0-9]+\.[0-9]+\.[0-9]+"/"version": "'"$NEW_VERSION"'"/'

bump_file "sdk/rust/Cargo.toml" \
  's/^version = "[0-9]+\.[0-9]+\.[0-9]+"/version = "'"$NEW_VERSION"'"/'

bump_file "sdk/python/pyproject.toml" \
  's/^version = "[0-9]+\.[0-9]+\.[0-9]+"/version = "'"$NEW_VERSION"'"/'

# Regenerate package-lock.json
if [[ "$DRY_RUN" == false ]]; then
  echo ""
  echo "Regenerating package-lock.json..."
  (cd "$ROOT/sdk/typescript" && npm install --package-lock-only --silent 2>/dev/null)
  echo "  OK    sdk/typescript/package-lock.json"
fi

echo ""
echo "Done. Verify with:"
echo "  grep -rn 'version' core/mix.exs sdk/elixir/mix.exs sdk/typescript/package.json sdk/rust/Cargo.toml sdk/python/pyproject.toml | grep '$NEW_VERSION'"

if [[ "$COMMIT" == true && "$DRY_RUN" == false ]]; then
  echo ""
  echo "Committing..."
  cd "$ROOT"
  git add \
    core/mix.exs \
    sdk/elixir/mix.exs \
    sdk/typescript/package.json \
    sdk/typescript/package-lock.json \
    sdk/rust/Cargo.toml \
    sdk/python/pyproject.toml
  git commit -m "chore: bump version to $NEW_VERSION"
  echo "Committed. Don't forget to update CHANGELOG.md."
fi
