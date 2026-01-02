//! Example 04: Templates
//!
//! This example demonstrates:
//! - `.template()` for reusable configurations
//! - `.from()` to inherit template settings
//! - Override template settings per-task
//!
//! Templates eliminate repetition. Define container, mounts,
//! and environment once, reuse across many tasks.
//!
//! Run with: sykli run

use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    // === RESOURCES ===
    let src = p.dir(".");
    let registry_cache = p.cache("cargo-registry");
    let target_cache = p.cache("cargo-target");
    let npm_cache = p.cache("npm-cache");

    // === TEMPLATES ===

    // Rust template - common config for all Rust tasks
    let rust = p.template("rust")
        .container("rust:1.75")
        .mount(&src, "/src")
        .mount_cache(&registry_cache, "/usr/local/cargo/registry")
        .mount_cache(&target_cache, "/src/target")
        .workdir("/src")
        .env("CARGO_INCREMENTAL", "0");

    // Node template - for JS tooling
    let node = p.template("node")
        .container("node:20-slim")
        .mount(&src, "/src")
        .mount_cache(&npm_cache, "/root/.npm")
        .workdir("/src");

    // === TASKS ===

    // All Rust tasks inherit from the rust template
    // Only task-specific config needed now!
    p.task("lint").from(&rust).run("cargo clippy -- -D warnings");
    p.task("test").from(&rust).run("cargo test");

    // Override template settings when needed
    p.task("build")
        .from(&rust)
        .env("RUSTFLAGS", "-C target-cpu=native")  // Adds to template env
        .run("cargo build --release")
        .output("binary", "target/release/app")
        .after(&["lint", "test"]);

    // Different template for JS tasks
    p.task("docs")
        .from(&node)
        .run("npm run build:docs");

    p.emit();
}

// Without templates (repetitive):
//   p.task("lint").container("rust:1.75").mount(&src, "/src")...
//   p.task("test").container("rust:1.75").mount(&src, "/src")...
//   p.task("build").container("rust:1.75").mount(&src, "/src")...
//
// With templates (DRY):
//   let rust = p.template("rust").container("rust:1.75").mount(&src, "/src")...
//   p.task("lint").from(&rust).run("cargo clippy");
//   p.task("test").from(&rust).run("cargo test");
//   p.task("build").from(&rust).run("cargo build");
