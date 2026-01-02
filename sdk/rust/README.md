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
sykli = "0.2"

[[bin]]
name = "sykli"
path = "src/bin/sykli.rs"
```

For optional dependency (recommended for libraries):

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
    .run("cargo build --release -o ./app")
    .output("binary", "./app");
```

### Conditional Execution

Run tasks based on branch, tag, or event:

```rust
// String-based conditions
p.task("deploy")
    .run("./deploy.sh")
    .when("branch == 'main'");

// Type-safe conditions (compile-time checked)
use sykli::{Branch, Tag};

p.task("release")
    .run("./release.sh")
    .when_cond(Branch::new("main").or(Tag::pattern("v*")));
```

## Templates

Templates eliminate repetition:

```rust
let src = p.dir(".");
let cache = p.cache("cargo-registry");

// Define template
let rust = p.template("rust")
    .container("rust:1.75")
    .mount(&src, "/src")
    .mount_cache(&cache, "/usr/local/cargo/registry")
    .workdir("/src");

// Tasks inherit from template
p.task("lint").from(&rust).run("cargo clippy");
p.task("test").from(&rust).run("cargo test");
p.task("build").from(&rust).run("cargo build --release");
```

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

```rust
let checks = p.parallel("checks", vec![
    p.task("lint").run("cargo clippy"),
    p.task("fmt").run("cargo fmt --check"),
    p.task("test").run("cargo test"),
]);

// Build depends on all checks
p.task("build")
    .run("cargo build --release")
    .after_group(&checks);
```

### Chains

```rust
let test = p.task("test").run("cargo test");
let build = p.task("build").run("cargo build --release");
let deploy = p.task("deploy").run("./deploy.sh");

// test -> build -> deploy
p.chain(&[&test, &build, &deploy]);
```

### Artifact Passing

```rust
p.task("build")
    .run("cargo build --release -o /out/app")
    .output("binary", "/out/app");

// Automatically depends on "build"
p.task("package")
    .run("docker build -t myapp .")
    .input_from("build", "binary", "./app");
```

## Matrix Builds

```rust
// Test across Rust versions
p.matrix("rust-test", &["1.70", "1.75", "1.80"], |version| {
    p.task(&format!("test-rust-{}", version))
        .container(&format!("rust:{}", version))
        .mount_cwd()
        .run("cargo test")
});

// Deploy to environments
p.matrix_map("deploy", &[
    ("staging", "staging.example.com"),
    ("prod", "prod.example.com"),
], |(env, host)| {
    p.task(&format!("deploy-{}", env))
        .run(&format!("deploy --host {}", host))
        .when("branch == 'main'")
});
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
use sykli::{FromEnv, FromVault, FromFile};

p.task("deploy")
    .secret_from("GITHUB_TOKEN", FromEnv::new("GH_TOKEN"))
    .secret_from("DB_PASSWORD", FromVault::new("secret/db#password"))
    .secret_from("API_KEY", FromFile::new("/run/secrets/api-key"))
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

```rust
use sykli::{K8sOptions, K8sResources};

// Pipeline-level defaults
let mut p = Pipeline::new_with_k8s_defaults(K8sOptions {
    namespace: Some("ci-jobs".into()),
    resources: K8sResources {
        memory: Some("2Gi".into()),
        ..Default::default()
    },
    ..Default::default()
});

// Task-specific K8s settings
p.task("train-model")
    .container("pytorch/pytorch:2.0")
    .run("python train.py")
    .k8s(K8sOptions {
        gpu: Some(1),
        resources: K8sResources {
            memory: Some("32Gi".into()),
            ..Default::default()
        },
        node_selector: [("gpu".into(), "nvidia-a100".into())].into(),
        ..Default::default()
    });

// Hybrid: local + k8s
p.task("test").run("cargo test").target("local");
p.task("train").run("python train.py").target("k8s");
```

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

p.explain(&ExplainContext {
    branch: "feature/foo".into(),
    tag: None,
    ci: true,
});

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
