#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

copy_fixture() {
  mkdir -p "$TMP_DIR/scripts" "$TMP_DIR/core" "$TMP_DIR/sdk/elixir" "$TMP_DIR/sdk/rust" "$TMP_DIR/sdk/python" "$TMP_DIR/sdk/typescript" "$TMP_DIR/sdk/go"

  cp "$ROOT/scripts/bump-version.sh" "$TMP_DIR/scripts/bump-version.sh"
  cp "$ROOT/scripts/check-version.sh" "$TMP_DIR/scripts/check-version.sh"

  printf '0.6.0\n' > "$TMP_DIR/VERSION"
  printf 'defmodule Sykli.MixProject do\n  @version "0.6.0"\nend\n' > "$TMP_DIR/core/mix.exs"
  printf 'defmodule SykliSdk.MixProject do\n  def project, do: [version: "0.6.0"]\nend\n' > "$TMP_DIR/sdk/elixir/mix.exs"
  printf '[package]\nname = "sykli"\nversion = "0.6.0"\n' > "$TMP_DIR/sdk/rust/Cargo.toml"
  printf '[project]\nname = "sykli"\nversion = "0.6.0"\n' > "$TMP_DIR/sdk/python/pyproject.toml"
  printf '{\n  "name": "sykli",\n  "version": "0.6.0"\n}\n' > "$TMP_DIR/sdk/typescript/package.json"
  printf '{\n  "name": "sykli",\n  "version": "0.6.0",\n  "packages": {\n    "": {\n      "name": "sykli",\n      "version": "0.6.0"\n    }\n  }\n}\n' > "$TMP_DIR/sdk/typescript/package-lock.json"
  printf 'module github.com/yairfalse/sykli/sdk/go\n\ngo 1.21\n' > "$TMP_DIR/sdk/go/go.mod"
}

assert_contains() {
  local path="$1"
  local expected="$2"

  if ! grep -Fq "$expected" "$path"; then
    echo "[release-test] expected $path to contain: $expected" >&2
    exit 1
  fi
}

copy_fixture

"$TMP_DIR/scripts/check-version.sh"
"$TMP_DIR/scripts/bump-version.sh" 1.2.3
"$TMP_DIR/scripts/check-version.sh"

assert_contains "$TMP_DIR/VERSION" "1.2.3"
assert_contains "$TMP_DIR/core/mix.exs" '@version "1.2.3"'
assert_contains "$TMP_DIR/sdk/elixir/mix.exs" 'version: "1.2.3"'
assert_contains "$TMP_DIR/sdk/rust/Cargo.toml" 'version = "1.2.3"'
assert_contains "$TMP_DIR/sdk/python/pyproject.toml" 'version = "1.2.3"'
assert_contains "$TMP_DIR/sdk/typescript/package.json" '"version": "1.2.3"'
assert_contains "$TMP_DIR/sdk/typescript/package-lock.json" '"version": "1.2.3"'

echo "[release-test] release script smoke tests passed"
