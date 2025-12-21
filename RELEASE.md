# Sykli v1.0.0 Release

**Target**: First public release enabling teams to adopt sykli

---

## What's in v1

### Core (Elixir)
- [x] Parallel task execution by dependency levels
- [x] Content-addressed caching (local `.sykli/cache`)
- [x] Multi-language SDK detection (Go, Rust, Elixir)
- [x] Cycle detection with helpful error messages
- [x] GitHub status API integration
- [x] Distributed observability (Events, Coordinator, Reporter)
- [x] Run Registry for tracking execution history
- [x] Configurable timeouts and buffer limits

### SDKs
- [x] **Go SDK** - `sykli.dev/go`
- [x] **Rust SDK** - `sykli` crate
- [x] **Elixir SDK** - `sykli` hex package

### SDK Features (all languages)
- [x] Task definition with `.run()` / `Run()`
- [x] Dependencies with `.after()` / `After()`
- [x] Input file specification for caching
- [x] Cycle detection before emit
- [x] Logging integration

---

## Distribution Plan

### 1. Escript Binary (Core)
Build a self-contained `sykli` binary that works on any system with Erlang/OTP.

```bash
cd core
mix escript.build
# produces: ./sykli
```

### 2. Rust SDK → crates.io
```bash
cd sdk/rust
cargo publish
```
Users add: `sykli = "0.1"`

### 3. Elixir SDK → hex.pm
```bash
cd sdk/elixir
mix hex.publish
```
Users add: `{:sykli, "~> 0.1"}`

### 4. Go SDK → GitHub
Go modules work directly from GitHub:
```go
import sykli "github.com/yairfalse/sykli/sdk/go"
```

After tagging v1.0.0, users can do:
```bash
go get github.com/yairfalse/sykli/sdk/go@v1.0.0
```

---

## Release Checklist

- [ ] Update version numbers to 1.0.0
  - [ ] `core/mix.exs`
  - [ ] `sdk/rust/Cargo.toml`
  - [ ] `sdk/elixir/mix.exs`
  - [ ] `sdk/go/go.mod` (if using vanity imports)
- [ ] Add escript configuration to core/mix.exs
- [ ] Test escript build and execution
- [ ] Verify all 147 tests pass
- [ ] Create GitHub release tag v1.0.0
- [ ] Publish Rust SDK to crates.io
- [ ] Publish Elixir SDK to hex.pm
- [ ] Update CLAUDE.md to reflect released features
- [ ] Update README with installation instructions

---

## Post-v1 Roadmap

- [ ] Remote cache backend (S3/GCS)
- [ ] Docker image for CI environments
- [ ] GitHub Action for easy CI integration
- [ ] LiveView dashboard for distributed observability
- [ ] TypeScript SDK

---

## Usage After Release

### Rust Project (e.g., kulta)
```toml
# Cargo.toml
[dependencies]
sykli = { version = "0.1", optional = true }

[features]
sykli = ["dep:sykli"]
```

### Go Project
```go
// sykli.go
import "github.com/yairfalse/sykli/sdk/go"
```

### Elixir Project
```elixir
# mix.exs
{:sykli, "~> 0.1"}

# sykli.exs
use Sykli.DSL
```

### Running
```bash
# Install sykli (one-time)
mix escript.install github yairfalse/sykli path:core

# Run in project
sykli
```
