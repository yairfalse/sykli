//! Example 03: Container Execution
//!
//! This example demonstrates:
//! - `.container()` for isolated execution
//! - `.dir()` and `.cache()` resources
//! - `.mount()` and `.mount_cache()` for volumes
//! - `.workdir()` for working directory
//! - `.env()` for environment variables
//!
//! Run with: sykli run

use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    // === RESOURCES ===

    // Source directory - mounted into containers
    let src = p.dir(".");

    // Named caches - persist across runs
    let registry_cache = p.cache("cargo-registry");
    let target_cache = p.cache("cargo-target");

    // === TASKS ===

    // Lint in container with source mounted
    p.task("lint")
        .container("rust:1.75")
        .mount(&src, "/src")
        .mount_cache(&registry_cache, "/usr/local/cargo/registry")
        .workdir("/src")
        .run("cargo clippy -- -D warnings");

    // Test with multiple caches
    p.task("test")
        .container("rust:1.75")
        .mount(&src, "/src")
        .mount_cache(&registry_cache, "/usr/local/cargo/registry")
        .mount_cache(&target_cache, "/src/target")
        .workdir("/src")
        .run("cargo test");

    // Build with environment variable
    p.task("build")
        .container("rust:1.75")
        .mount(&src, "/src")
        .mount_cache(&registry_cache, "/usr/local/cargo/registry")
        .mount_cache(&target_cache, "/src/target")
        .workdir("/src")
        .env("CARGO_INCREMENTAL", "0")
        .run("cargo build --release")
        .output("binary", "target/release/app")
        .after(&["lint", "test"]);

    // === CONVENIENCE METHODS ===

    // mount_cwd() is shorthand for mounting . to /work
    p.task("check-format")
        .container("rust:1.75")
        .mount_cwd() // Mounts current dir to /work, sets workdir
        .run("cargo fmt --check");

    p.emit();
}

// Key concepts:
// - dir(".")      - Represents a host directory
// - cache("name") - Named persistent cache volume
// - mount(&d, p)  - Mount directory at container path
// - mount_cache() - Mount cache for faster builds
// - workdir()     - Set container working directory
