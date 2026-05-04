# Sykli Rust SDK

CI pipelines defined in Rust instead of YAML.

```rust
use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("test").run("cargo test");
    p.task("build").run("cargo build --release").after(&["test"]);
    p.emit();
}
```

## Installation

Add to your `Cargo.toml`:

```toml
[dependencies]
sykli = "0.6"

[[bin]]
name = "sykli"
path = "src/bin/sykli.rs"
```

For optional dependency (recommended for libraries):

```toml
[features]
sykli = ["dep:sykli"]

[dependencies]
sykli = { version = "0.6", optional = true }

[[bin]]
name = "sykli"
path = "src/bin/sykli.rs"
required-features = ["sykli"]
```

## Quick Start

Create `src/bin/sykli.rs`:

```rust
use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    p.task("lint").run("cargo clippy -- -D warnings");
    p.task("test").run("cargo test");
    p.task("build")
        .run("cargo build --release")
        .after(&["lint", "test"]);

    p.emit();
}
```

Create an empty `sykli.rs` in your project root:

```bash
touch sykli.rs
```

Run:

```bash
sykli run
```

## Core Concepts

### Tasks

Tasks are the basic unit of work:

```rust
p.task("test").run("cargo test");
```

### Dependencies

Define execution order with `.after()`:

```rust
p.task("deploy")
    .run("./deploy.sh")
    .after(&["build", "test"]);  // Runs after both complete
```

Independent tasks run in parallel automatically.

### Input-Based Caching

Skip unchanged tasks with `.inputs()`:

```rust
p.task("test")
    .run("cargo test")
    .inputs(&["**/*.rs", "Cargo.toml", "Cargo.lock"]);
```

### Outputs

Declare task outputs for artifact passing:

```rust
p.task("build")
    .run("cargo build --release")
    .output("binary", "target/release/app");
```

### Conditional Execution

Run tasks based on branch, tag, or event:

```rust
// String-based conditions
p.task("deploy")
    .run("./deploy.sh")
    .when("branch == 'main'");

// Type-safe conditions (compile-time checked)
use sykli::Condition;

p.task("release")
    .run("./release.sh")
    .when_cond(Condition::branch("main").or(Condition::tag("v*")));
```

Available condition builders:

- `Condition::branch("main")` / `Condition::branch("feature/*")`
- `Condition::tag("v*")` / `Condition::has_tag()`
- `Condition::event("push")` / `Condition::event("pull_request")`
- `Condition::in_ci()`
- `Condition::negate(c)`, `.and(other)`, `.or(other)`

## Templates

Templates eliminate repetition. Construct with `Template::new()` and apply with `.from()`:

```rust
use sykli::Template;

let src = p.dir(".");
let cache = p.cache("cargo-registry");

let rust = Template::new()
    .container("rust:1.75")
    .mount_dir(&src, "/src")
    .mount_cache(&cache, "/usr/local/cargo/registry")
    .workdir("/src");

p.task("lint").from(&rust).run("cargo clippy");
p.task("test").from(&rust).run("cargo test");
p.task("build").from(&rust).run("cargo build --release");
```

Task-specific settings override template settings.

## Containers

Run tasks in isolated containers:

```rust
let src = p.dir(".");
let registry_cache = p.cache("cargo-registry");
let target_cache = p.cache("cargo-target");

p.task("test")
    .container("rust:1.75")
    .mount(&src, "/src")
    .mount_cache(&registry_cache, "/usr/local/cargo/registry")
    .mount_cache(&target_cache, "/src/target")
    .workdir("/src")
    .run("cargo test");
```

### Convenience Methods

```rust
// Mount current dir to /work
p.task("test")
    .container("rust:1.75")
    .mount_cwd()
    .run("cargo test");

// Mount to custom path
p.task("build")
    .container("rust:1.75")
    .mount_cwd_at("/app")
    .run("cargo build");
```

## Composition

### Parallel Groups

`parallel()` groups already-defined tasks by name. Define the tasks first, then group them:

```rust
p.task("lint").run("cargo clippy");
p.task("fmt").run("cargo fmt --check");
p.task("test").run("cargo test");

let checks = p.parallel("checks", &["lint", "fmt", "test"]);

// Build depends on all checks
p.task("build")
    .run("cargo build --release")
    .after_group(&checks);
```

### Chains

`chain()` takes a slice of task names and adds sequential dependencies:

```rust
p.task("test").run("cargo test");
p.task("build").run("cargo build --release");
p.task("deploy").run("./deploy.sh");

// build depends on test, deploy depends on build
p.chain(&["test", "build", "deploy"]);
```

### Artifact Passing

```rust
p.task("build")
    .run("cargo build --release")
    .output("binary", "target/release/app");

// Automatically depends on "build"
p.task("package")
    .run("docker build -t myapp .")
    .input_from("build", "binary", "./app");
```

## Matrix Builds

`matrix()` runs a generator closure once per value, producing a `TaskGroup`:

```rust
// Test across Rust versions
let versions = p.matrix("rust-test", &["1.70", "1.75", "1.80"], |p, version| {
    p.task(&format!("test-rust-{}", version))
        .container(&format!("rust:{}", version))
        .mount_cwd()
        .run("cargo test");
});

p.task("publish")
    .run("cargo publish")
    .after_group(&versions);
```

## Service Containers

```rust
p.task("integration")
    .container("rust:1.75")
    .mount_cwd()
    .service("postgres:15", "db")
    .service("redis:7", "cache")
    .env("DATABASE_URL", "postgres://postgres:postgres@db:5432/test")
    .env("REDIS_URL", "redis://cache:6379")
    .run("cargo test --features integration")
    .timeout(300);
```

## Secrets

```rust
// Simple secret
p.task("deploy")
    .secret("DEPLOY_TOKEN")
    .run("./deploy.sh");

// Typed secrets with explicit source
use sykli::SecretRef;

p.task("deploy")
    .secret_from("GITHUB_TOKEN", SecretRef::from_env("GH_TOKEN"))
    .secret_from("DB_PASSWORD", SecretRef::from_vault("secret/data/db#password"))
    .secret_from("API_KEY", SecretRef::from_file("/run/secrets/api-key"))
    .run("./deploy.sh");
```

## Retry & Timeout

```rust
p.task("flaky-test")
    .run("./integration-test.sh")
    .retry(3)       // Retry up to 3 times
    .timeout(300);  // 5 minute timeout
```

## Kubernetes Execution

The Rust SDK exposes a minimal `K8sOptions` covering the 95% case (memory, CPU, GPU). For advanced fields (tolerations, affinity, security contexts, node selectors), pass raw JSON via `k8s_raw()`.

```rust
use sykli::{K8sOptions, Pipeline};

// Pipeline-level defaults
let mut p = Pipeline::with_k8s_defaults(K8sOptions {
    memory: Some("2Gi".into()),
    cpu: Some("1".into()),
    gpu: None,
});

// Task-specific K8s settings
p.task("train-model")
    .container("pytorch/pytorch:2.0")
    .run("python train.py")
    .k8s(K8sOptions {
        memory: Some("32Gi".into()),
        cpu: Some("4".into()),
        gpu: Some(1),
    });

// Advanced K8s configuration via raw JSON
p.task("gpu-train")
    .container("pytorch/pytorch:2.0")
    .run("python train.py")
    .k8s(K8sOptions {
        memory: Some("32Gi".into()),
        gpu: Some(1),
        ..Default::default()
    })
    .k8s_raw(r#"{"nodeSelector": {"gpu": "true"}, "tolerations": [{"key": "gpu", "effect": "NoSchedule"}]}"#);

// Hybrid: local + k8s
p.task("test").run("cargo test").target("local");
p.task("train").run("python train.py").target("k8s");
```

`K8sOptions` validates `memory` (e.g., `512Mi`, `4Gi`) and `cpu` (e.g., `500m`, `2`) at emit time and reports a `K8sValidationError` for malformed values.

## Language Presets

```rust
let mut p = Pipeline::new();

// Rust preset
p.rust().test();                                    // cargo test
p.rust().lint();                                    // cargo clippy
p.rust().build("target/release/app").after(&["test", "lint"]);

p.emit();
```

## Dry Run / Explain

```rust
use sykli::ExplainContext;

p.explain(Some(&ExplainContext {
    branch: "feature/foo".into(),
    tag: String::new(),
    event: String::new(),
    ci: true,
}));

// Output shows execution order and skipped tasks
```

## Examples

See the [examples directory](./examples/) for complete working examples:

- `01-basic/` - Tasks, dependencies, parallel execution
- `02-caching/` - Input-based caching and conditions
- `03-containers/` - Container execution with mounts
- `04-templates/` - DRY configuration with templates
- `05-composition/` - Parallel groups, chains, artifacts
- `06-matrix/` - Matrix builds, services, secrets

## API Reference

See [REFERENCE.md](./REFERENCE.md) for the complete API documentation.

## License

MIT
