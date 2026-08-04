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

## Automated registry publishing (tag-triggered)

Pushing a `v<version>` tag triggers `.github/workflows/release.yml`, which —
after building binaries and creating the GitHub release — publishes:

- **Go** — pushes the module-aware `sdk/go/v<version>` tag (skips if it
  already exists). No credentials; uses the workflow's `GITHUB_TOKEN`.
- **PyPI** — builds `sdk/python` and publishes via **trusted publishing**
  (OIDC). No token anywhere.
- **crates.io** — publishes `sdk/rust` via **trusted publishing** (OIDC).
  No token anywhere.
- **npm** — not yet automated; see below.
- **Hex** — not automated (hex.pm has no OIDC trusted publishing); publish
  with `scripts/publish-elixir.sh <version>` and `HEX_API_KEY`.

### One-time registry setup (required before the first automated publish)

**PyPI** (works even though `sykli` has never been published — "pending
publisher"): pypi.org → Your account → Publishing → *Add a new pending
publisher* with exactly:

| Field | Value |
|---|---|
| PyPI project name | `sykli` |
| Owner | `false-systems` |
| Repository name | `sykli` |
| Workflow name | `release.yml` |
| Environment name | `pypi` |

**crates.io** (the `sykli` crate exists, so configure on the crate):
crates.io → `sykli` → Settings → Trusted Publishing → *Add* with repository
owner `false-systems`, repository `sykli`, workflow filename `release.yml`,
environment left empty.

**npm**: trusted publishing can only be configured on an existing package.
After the first manual `npm publish` from `sdk/typescript`, configure the
trusted publisher on npmjs.com (package Settings → Trusted publisher:
GitHub Actions, repository `false-systems/sykli-elixir`, workflow `release.yml`)
and uncomment the `publish-npm` job in `release.yml`.

The publish jobs run after the GitHub release is created, so a registry
failure never blocks the binary release — fix the registry side and re-run
the failed job from the Actions UI.

## Release candidates

A version containing a `-` (e.g. `0.9.0-rc.1`) is a prerelease end to end.
Use the `X.Y.Z-rc.N` form everywhere — `bump-version.sh` and
`check-version.sh` accept it, and each ecosystem maps it safely:

| Registry | Version as published | Default-install safety |
|---|---|---|
| GitHub release | tag `v0.9.0-rc.1` | marked prerelease, never "latest" (workflow derives both from the `-` in the tag) |
| Go | tag `sdk/go/v0.9.0-rc.1` | Go tooling never selects prerelease tags for `@latest` |
| PyPI | normalized to `0.9.0rc1` (PEP 440) | `pip install sykli` skips pre-releases by default |
| crates.io | `0.9.0-rc.1` | `sykli = "0.9"` never resolves to a prerelease |
| npm | `0.9.0-rc.1` under dist-tag `rc` | `npm install sykli` keeps serving stable; RCs install via `sykli@rc` (`publish-ts.sh` and the workflow job apply the tag automatically) |
| Hex | `0.9.0-rc.1` | `~>` requirements never match prereleases |

Before tagging an RC:

1. `docs/releases/v<version>.md` must exist — the release job reads it via
   `body_path` and fails without it.
2. `scripts/bump-version.sh <version> --dry-run`, then without `--dry-run`.
3. Registry versions are immutable: an abandoned RC is left in place
   (superseded by `-rc.2`), never deleted.

Promoting an RC to final is a fresh release of `X.Y.Z` through the same
pipeline — never a re-tag of the RC artifacts.

## Publish Credentials (manual script path)

`make publish` / `scripts/publish-all.sh` remain available as the manual
path (and the only path for Hex, plus npm until its first publish). Actual
publishing requires all credentials to be present before the first
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
