#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
DRY_RUN=0
FROM="go"

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --from=*) FROM="${1#--from=}" ;;
    --from) FROM="${2:-}"; shift ;;
    *) echo "[publish-all] error: unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

[[ -n "$VERSION" ]] || { echo "Usage: scripts/publish-all.sh <version> [--dry-run] [--from <go|rust|ts|python|elixir>]" >&2; exit 1; }

echo "[publish-all] target version: $VERSION"
"$ROOT/scripts/check-version.sh"

case "$FROM" in
  go|rust|ts|python|elixir) ;;
  *) echo "[publish-all] error: --from must be one of go, rust, ts, python, elixir" >&2; exit 1 ;;
esac

if [[ "$DRY_RUN" -eq 0 ]]; then
  missing=0
  [[ -n "${CARGO_REGISTRY_TOKEN:-}" ]] || { echo "[publish-all] error: CARGO_REGISTRY_TOKEN is required" >&2; missing=1; }
  [[ -n "${NPM_TOKEN:-}" ]] || { echo "[publish-all] error: NPM_TOKEN is required" >&2; missing=1; }
  [[ -n "${PYPI_API_TOKEN:-}" || -n "${TWINE_PASSWORD:-}" ]] || { echo "[publish-all] error: PYPI_API_TOKEN or TWINE_PASSWORD is required" >&2; missing=1; }
  if [[ -z "${PYPI_API_TOKEN:-}" && -n "${TWINE_PASSWORD:-}" && -z "${TWINE_USERNAME:-}" ]]; then
    echo "[publish-all] error: TWINE_USERNAME is required when using TWINE_PASSWORD without PYPI_API_TOKEN" >&2
    missing=1
  fi
  [[ -n "${HEX_API_KEY:-}" ]] || { echo "[publish-all] error: HEX_API_KEY is required" >&2; missing=1; }
  git remote get-url origin >/dev/null || { echo "[publish-all] error: git remote 'origin' is required for Go tag publishing" >&2; missing=1; }

  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
fi

args=()
if [[ "$DRY_RUN" -eq 1 ]]; then
  args+=(--dry-run)
fi

publishers=(go rust ts python elixir)
started=0
for publisher in "${publishers[@]}"; do
  if [[ "$publisher" == "$FROM" ]]; then
    started=1
  fi

  if [[ "$started" -eq 0 ]]; then
    echo "[publish-all] skip $publisher before --from=$FROM"
    continue
  fi

  "$ROOT/scripts/publish-$publisher.sh" "$VERSION" "${args[@]}"
done
