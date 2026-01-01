# sykli

CI pipelines defined in Rust instead of YAML.

## Setup

### Option 1: Add to Existing Project

1. Add `sykli` to your `Cargo.toml`:

```toml
[dependencies]
sykli = "0.2"

[[bin]]
name = "sykli"
path = "src/bin/sykli.rs"
```

2. Create `src/bin/sykli.rs`:

```rust
use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("test").run("cargo test");
    p.task("build").run("cargo build --release").after(&["test"]);
    p.emit();
}
```

3. Create an empty `sykli.rs` file in your project root (sykli looks for this):

```bash
touch sykli.rs
```

4. Run:

```bash
sykli
```

### Option 2: Workspace Projects

For Cargo workspaces, add to the workspace root `Cargo.toml`:

```toml
[workspace]
members = ["crate-a", "crate-b"]

[workspace.dependencies]
sykli = "0.2"

# Add a workspace-level binary
[[bin]]
name = "sykli"
path = "sykli.rs"

[dependencies]
sykli = { workspace = true }
```

Then create `sykli.rs` in the workspace root with your pipeline.

### Option 3: Feature Flag (Recommended for Libraries)

If you don't want sykli as a regular dependency:

```toml
[features]
sykli = ["dep:sykli"]

[dependencies]
sykli = { version = "0.2", optional = true }

[[bin]]
name = "sykli"
path = "src/bin/sykli.rs"
required-features = ["sykli"]
```

This keeps your release builds clean - `sykli` is only compiled when running the pipeline.

## Quick Start

```rust
use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    p.task("test").run("cargo test");
    p.task("lint").run("cargo clippy -- -D warnings");
    p.task("build")
        .run("cargo build --release")
        .after(&["test", "lint"]);

    p.emit();
}
```

## Features

- **Task dependencies** - Define execution order with `.after()`
- **Input-based caching** - Skip unchanged tasks with `.inputs()`
- **Parallel execution** - Independent tasks run concurrently
- **Cycle detection** - Catches dependency cycles before execution
- **Conditional execution** - Run tasks based on branch/tag with `.when()`
- **Matrix builds** - Run tasks across multiple configurations
- **Service containers** - Background services for integration tests
- **Retry & timeout** - Resilience for flaky tasks

## With Caching

```rust
p.task("test")
    .run("cargo test")
    .inputs(&["**/*.rs", "Cargo.toml", "Cargo.lock"]);
```

## Conditional Execution

```rust
p.task("deploy")
    .run("./deploy.sh")
    .when("branch == 'main'")
    .secret("DEPLOY_TOKEN");
```

## Matrix Builds

```rust
p.task("test")
    .run("cargo test")
    .matrix("rust_version", &["1.70", "1.75", "1.80"]);
```

## Rust Preset

```rust
let mut p = Pipeline::new();
p.rust().test();
p.rust().lint();
p.rust().build("target/release/app").after(&["test", "lint"]);
p.emit();
```

## License

MIT
