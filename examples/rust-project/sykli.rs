//! Sykli CI definition for this Rust project.
//!
//! Run with: cargo run --bin sykli -- --emit
//! The `--emit` flag triggers the pipeline to output its JSON definition to stdout.

use sykli::Pipeline;

fn main() {
    let mut s = Pipeline::new();

    // === RESOURCES ===
    let src = s.dir(".");
    let cargo_registry = s.cache("cargo-registry");
    let cargo_git = s.cache("cargo-git");
    let target_cache = s.cache("target");

    // === TASKS ===

    // Lint - runs in container with caches
    s.task("lint")
        .container("rust:1.75")
        .mount(&src, "/src")
        .mount_cache(&cargo_registry, "/usr/local/cargo/registry")
        .mount_cache(&cargo_git, "/usr/local/cargo/git")
        .workdir("/src")
        .run("cargo clippy -- -D warnings");

    // Test - runs in container with caches
    s.task("test")
        .container("rust:1.75")
        .mount(&src, "/src")
        .mount_cache(&cargo_registry, "/usr/local/cargo/registry")
        .mount_cache(&cargo_git, "/usr/local/cargo/git")
        .mount_cache(&target_cache, "/src/target")
        .workdir("/src")
        .run("cargo test");

    // Build - depends on lint and test
    s.task("build")
        .container("rust:1.75")
        .mount(&src, "/src")
        .mount_cache(&cargo_registry, "/usr/local/cargo/registry")
        .mount_cache(&cargo_git, "/usr/local/cargo/git")
        .mount_cache(&target_cache, "/src/target")
        .workdir("/src")
        .run("cargo build --release")
        .output("binary", "target/release/rust-project")
        .after(&["lint", "test"]);

    s.emit();
}
