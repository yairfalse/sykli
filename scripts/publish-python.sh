#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
DRY_RUN=0

shift || true
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "[publish-python] error: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "Usage: scripts/publish-python.sh <version> [--dry-run]" >&2; exit 1; }

echo "[publish-python] package: sykli==$VERSION"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[publish-python] dry run: would build and upload sdk/python to PyPI"
  exit 0
fi

if [[ -z "${PYPI_API_TOKEN:-}" && -z "${TWINE_PASSWORD:-}" ]]; then
  echo "[publish-python] error: PYPI_API_TOKEN or TWINE_PASSWORD is required" >&2
  exit 1
fi

if [[ -z "${PYPI_API_TOKEN:-}" && -z "${TWINE_USERNAME:-}" ]]; then
  echo "[publish-python] error: TWINE_USERNAME is required when using TWINE_PASSWORD without PYPI_API_TOKEN" >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/../sdk/python"
rm -rf dist/ build/ *.egg-info/
python3 -m build
if [[ -n "${PYPI_API_TOKEN:-}" ]]; then
  TWINE_USERNAME=__token__ TWINE_PASSWORD="$PYPI_API_TOKEN" python3 -m twine upload dist/*
else
  python3 -m twine upload dist/*
fi
