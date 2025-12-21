# sykli

CI pipelines defined in Rust instead of YAML.

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
