//! Example 01: Basic Pipeline
//!
//! This example demonstrates:
//! - Creating tasks with `.run()`
//! - Defining dependencies with `.after()`
//! - Parallel execution of independent tasks
//!
//! Run with: sykli run

use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    // Independent tasks run in parallel
    p.task("lint").run("cargo clippy -- -D warnings");
    p.task("test").run("cargo test");

    // Build depends on both lint and test
    // It won't start until both complete successfully
    p.task("build")
        .run("cargo build --release")
        .after(&["lint", "test"]);

    // Deploy depends on build
    // Only runs after build completes
    p.task("deploy")
        .run("echo 'Deploying...'")
        .after(&["build"]);

    p.emit();
}

// Expected execution order:
//
// Level 0 (parallel):  lint, test
// Level 1:             build
// Level 2:             deploy
//
// Total: 4 tasks in 3 levels
