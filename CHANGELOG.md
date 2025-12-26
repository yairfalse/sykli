# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2025-12-26

### Added

- **Pure K8s REST API client** - No more kubectl dependency for K8s target
  - Custom auth detection (in-cluster service account, kubeconfig)
  - Typed errors with retry logic for transient failures
  - Job lifecycle management (create, wait, logs, delete)
- **Target abstraction** - Unified interface for execution backends
  - `Local` target for laptop/CI runner execution
  - `K8s` target for Kubernetes cluster execution
  - Same pipeline definition works on both
- **sykli delta** - Run only tasks affected by git changes
- **sykli graph** - DAG visualization (Mermaid/DOT output)
- **Templates** - Reusable task configurations
- **Parallel combinator** - Concurrent task groups (`Parallel("name", task1, task2)`)
- **Chain combinator** - Sequential pipelines (`Chain(task1, task2, task3)`)
- **Output declarations** - Tasks can declare outputs (`Output("name", "./path")`)
- **Artifact passing** - Tasks can consume outputs (`InputFrom(task, "output", "/dest")`)
- **Conditional execution** - `When("branch == 'main'")`
- **DX improvements** - Type-safe conditions, typed secrets, K8s validation
- **Structured errors** - TaskError with hints, duration, and formatted output
- **Distributed observability** - BEAM-powered multi-node awareness

### Changed

- Elixir SDK renamed to `sykli_sdk` on hex.pm
- Improved path traversal prevention in artifact copying

### Fixed

- Burrito binary detection (correct env var check)
- Output flushing in CLI commands
- Volume name collisions in K8s target (hash suffix)
- Path traversal vulnerability in local storage

## [0.1.3] - 2025-12-23

### Added

- Quick start guide when no sykli file found
- Improved help output

### Fixed

- Release workflow: update Zig to 0.15.2 and macOS runner

## [0.1.2] - 2025-12-22

### Added

- Rust SDK with rustfmt formatting

## [0.1.1] - 2025-12-22

### Added

- Initial release with Go, Rust, and Elixir SDKs
- Content-addressed caching (local)
- Container execution with mounts
- GitHub status API integration
- Burrito binary distribution
