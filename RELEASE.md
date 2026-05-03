# Release Automation

Sykli releases are driven by a single root `VERSION` file. Package manifests in
the core engine and every SDK are derived from that file by script; release
operators should not edit SDK version numbers by hand.

## Prerequisites

- `git` 2.x or newer
- `python3` for version manifest management
- Core and SDK toolchains needed by the release gate: Elixir/Mix, Go, Rust,
  Node/npm, and Python packaging tools

## Commands

```bash
make dry-run VERSION=0.6.0
make release VERSION=0.6.0
make publish VERSION=0.6.0
```

`make release` validates the repository, runs the core test suite, runs every SDK
test suite, runs cross-SDK conformance, bumps version files, commits
`release: v0.6.0`, and creates tag `v0.6.0`.

`make publish` publishes SDK packages only. It checks all required credentials
before publishing anything.

## Version Checks

```bash
scripts/check-version.sh
scripts/bump-version.sh 0.6.1 --dry-run
scripts/bump-version.sh 0.6.1
```

Checked files:

- `VERSION`
- `core/mix.exs`
- `sdk/elixir/mix.exs`
- `sdk/rust/Cargo.toml`
- `sdk/python/pyproject.toml`
- `sdk/typescript/package.json`
- `sdk/typescript/package-lock.json`
- `sdk/go/go.mod`

The Go SDK has no embedded package version. It publishes via the module-aware
tag `sdk/go/v<version>`.

## Publish Credentials

Actual publishing requires all credentials to be present before the first
registry call:

- `CARGO_REGISTRY_TOKEN` for crates.io
- `NPM_TOKEN` for npm
- `PYPI_API_TOKEN` or `TWINE_PASSWORD` for PyPI
- `HEX_API_KEY` for Hex
- a configured `origin` git remote for the Go module tag

If `TWINE_PASSWORD` is used without `PYPI_API_TOKEN`, set `TWINE_USERNAME`
explicitly. Otherwise the publish script fails rather than inheriting an
unrelated ambient PyPI username.

Dry runs do not require credentials.

## Partial Publish Recovery

Multi-registry publishing cannot be atomic. If `make publish` fails mid-flight,
do not rerun from the beginning unless you have confirmed the earlier registries
did not publish. Fix the failure, then resume from the failed package:

```bash
scripts/publish-all.sh 0.6.0 --from rust
```

Valid resume points are `go`, `rust`, `ts`, `python`, and `elixir`. Individual
registry semantics still apply: crates.io, npm, PyPI, and Hex generally cannot
delete published versions, so already-published packages should be treated as
complete and skipped on retry. The Go SDK publishes through the module-aware git
tag `sdk/go/v<version>`, which can be inspected and repaired with normal git tag
operations.

## Example Dry Run

```text
$ make dry-run VERSION=0.6.0
[release] release v0.6.0
[release] checking version consistency before bump
[release] + scripts/check-version.sh
[release] running core tests
[release] + bash -lc cd core && mix test
[release] running SDK tests
[release] + bash -lc cd sdk/go && go test ./...
[release] running cross-SDK conformance
[release] + tests/conformance/run.sh
[release] would commit release: v0.6.0
[release] would tag v0.6.0
[publish-go] tag: sdk/go/v0.6.0
[publish-rust] dry run: would run cargo publish from sdk/rust
```

Dry run prints the commands it would execute and performs no mutation.
