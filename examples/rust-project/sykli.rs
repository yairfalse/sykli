//! Sykli CI definition for this Rust project.
//!
//! Run with: cargo run --bin sykli -- --emit
//! The `--emit` flag triggers the pipeline to output its JSON definition to stdout.

use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    // === RESOURCES ===
    let src = p.dir(".");
    let cargo_registry = p.cache("cargo-registry");
    let cargo_git = p.cache("cargo-git");
    let target_cache = p.cache("target");

    // === TASKS ===

    // Lint - runs in container with caches
    p.task("lint")
        .container("rust:1.75")
        .mount(&src, "/src")
        .mount_cache(&cargo_registry, "/usr/local/cargo/registry")
        .mount_cache(&cargo_git, "/usr/local/cargo/git")
        .workdir("/src")
        .run("cargo clippy -- -D warnings");

    // Test - runs in container with caches
    p.task("test")
        .container("rust:1.75")
        .mount(&src, "/src")
        .mount_cache(&cargo_registry, "/usr/local/cargo/registry")
        .mount_cache(&cargo_git, "/usr/local/cargo/git")
        .mount_cache(&target_cache, "/src/target")
        .workdir("/src")
        .run("cargo test");

    // Build - depends on lint and test
    p.task("build")
        .container("rust:1.75")
        .mount(&src, "/src")
        .mount_cache(&cargo_registry, "/usr/local/cargo/registry")
        .mount_cache(&cargo_git, "/usr/local/cargo/git")
        .mount_cache(&target_cache, "/src/target")
        .workdir("/src")
        .run("cargo build --release")
        .output("binary", "target/release/rust-project")
        .after(&["lint", "test"]);

    p.emit();
}
