//! Example 05: Composition
//!
//! This example demonstrates:
//! - `TaskGroup` for grouping related tasks
//! - `.chain()` for sequential pipelines
//! - `.input_from()` for artifact passing
//! - `.after_group()` for depending on task groups
//!
//! These combinators make complex pipelines readable.
//!
//! Run with: sykli run

use sykli::{Pipeline, TaskGroup, Template};

fn main() {
    let mut p = Pipeline::new();

    // === RESOURCES ===
    let src = p.dir(".");
    let registry_cache = p.cache("cargo-registry");
    let target_cache = p.cache("cargo-target");

    // === TEMPLATE ===
    let rust = Template::new()
        .container("rust:1.75")
        .mount_dir(&src, "/src")
        .mount_cache(&registry_cache, "/usr/local/cargo/registry")
        .mount_cache(&target_cache, "/src/target")
        .workdir("/src");

    // === PARALLEL GROUP ===
    // All checks run concurrently (no dependencies between them)
    p.task("lint")
        .from(&rust)
        .run("cargo clippy -- -D warnings");
    p.task("fmt").from(&rust).run("cargo fmt --check");
    p.task("test").from(&rust).run("cargo test");
    p.task("audit").from(&rust).run("cargo audit");

    // Create a TaskGroup to reference these tasks
    let checks = TaskGroup::new(
        "checks",
        vec![
            "lint".to_string(),
            "fmt".to_string(),
            "test".to_string(),
            "audit".to_string(),
        ],
    );

    // === BUILD ===
    // Depends on all checks passing
    p.task("build")
        .from(&rust)
        .env("RUSTFLAGS", "-C target-cpu=native")
        .run("cargo build --release")
        .output("binary", "target/release/app")
        .after_group(&checks);

    // === ARTIFACT PASSING ===
    // input_from automatically:
    // 1. Adds dependency on "build"
    // 2. Makes the artifact available at "./app"
    p.task("package")
        .container("docker:24")
        .mount_cwd()
        .run("docker build -t myapp:latest .")
        .input_from("build", "binary", "./app");

    // === CHAIN ===
    // Sequential dependencies using task names
    p.task("integration")
        .from(&rust)
        .run("cargo test --features integration")
        .after(&["build"]);

    p.task("e2e").run("./scripts/e2e.sh");

    p.task("deploy")
        .run("./scripts/deploy.sh")
        .when("branch == 'main'");

    // Chain creates: integration -> e2e -> deploy
    p.chain(&["integration", "e2e", "deploy"]);

    p.emit();
}

// Execution flow:
//
// [lint]  ─┐
// [fmt]   ─┼─> [build] ─> [package]
// [test]  ─┤
// [audit] ─┘
//            └──────────> [integration] ─> [e2e] ─> [deploy]
