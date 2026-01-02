//! Example 02: Input-Based Caching
//!
//! This example demonstrates:
//! - `.inputs()` for content-addressed caching
//! - `.output()` for declaring artifacts
//! - `.when()` for conditional execution
//!
//! Tasks with unchanged inputs are skipped on subsequent runs.
//!
//! Run with: sykli run

use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    // Test task with input patterns
    // If **/*.rs files haven't changed, this task is skipped
    p.task("test")
        .run("cargo test")
        .inputs(&["**/*.rs", "Cargo.toml", "Cargo.lock"]);

    // Build task with inputs and outputs
    // Skipped if inputs unchanged AND output exists
    p.task("build")
        .run("cargo build --release")
        .inputs(&["**/*.rs", "Cargo.toml", "Cargo.lock"])
        .output("binary", "target/release/app")
        .after(&["test"]);

    // Deploy only runs on main branch
    // Condition is evaluated at runtime
    p.task("deploy")
        .run("./deploy.sh")
        .when("branch == 'main'")
        .after(&["build"]);

    // Type-safe conditions (compile-time checked)
    // These are caught at compile time, not runtime
    p.task("release")
        .run("./release.sh")
        .when("branch == 'main' || tag matches 'v*'")
        .after(&["build"]);

    p.emit();
}

// First run:  All tasks execute (no cache)
// Second run: Tasks with unchanged inputs are skipped
// Third run:  Only changed files trigger re-execution
