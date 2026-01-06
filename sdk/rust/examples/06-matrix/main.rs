//! Example 06: Matrix Builds & Services
//!
//! This example demonstrates:
//! - Matrix-style builds with loops
//! - Service containers with `.service()`
//! - `.retry()` and `.timeout()` for resilience
//! - Secrets with `.secret()`
//!
//! Run with: sykli run

use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    let src = p.dir(".");

    // === MATRIX BUILDS ===

    // Pre-create caches for each version (outside the task chain)
    let cache_170 = p.cache("cargo-1.70");
    let cache_175 = p.cache("cargo-1.75");
    let cache_180 = p.cache("cargo-1.80");

    // Test across multiple Rust versions
    // Creates: test-rust-1.70, test-rust-1.75, test-rust-1.80
    p.task("test-rust-1.70")
        .container("rust:1.70")
        .mount(&src, "/src")
        .mount_cache(&cache_170, "/usr/local/cargo/registry")
        .workdir("/src")
        .run("cargo test");

    p.task("test-rust-1.75")
        .container("rust:1.75")
        .mount(&src, "/src")
        .mount_cache(&cache_175, "/usr/local/cargo/registry")
        .workdir("/src")
        .run("cargo test");

    p.task("test-rust-1.80")
        .container("rust:1.80")
        .mount(&src, "/src")
        .mount_cache(&cache_180, "/usr/local/cargo/registry")
        .workdir("/src")
        .run("cargo test");

    // === SERVICE CONTAINERS ===

    // Integration tests with database and cache services
    p.task("integration")
        .container("rust:1.75")
        .mount(&src, "/src")
        .workdir("/src")
        .service("postgres:15", "db") // Accessible as hostname "db"
        .service("redis:7", "cache") // Accessible as hostname "cache"
        .env(
            "DATABASE_URL",
            "postgres://postgres:postgres@db:5432/test?sslmode=disable",
        )
        .env("REDIS_URL", "redis://cache:6379")
        .run("cargo test --features integration")
        .timeout(300) // 5 minute timeout
        .after(&["test-rust-1.70", "test-rust-1.75", "test-rust-1.80"]);

    // === RETRY & TIMEOUT ===

    // Flaky tests with retry
    p.task("e2e")
        .container("playwright/playwright:latest")
        .mount(&src, "/src")
        .workdir("/src")
        .run("npm run e2e")
        .retry(3) // Retry up to 3 times
        .timeout(600) // 10 minute timeout
        .after(&["integration"]);

    // === SECRETS ===

    // Deployment with secrets
    p.task("publish")
        .run("cargo publish")
        .secret("CARGO_REGISTRY_TOKEN")
        .when("tag != ''")
        .after(&["e2e"]);

    // Deploy to staging
    p.task("deploy-staging")
        .run("./deploy.sh staging")
        .secret("DEPLOY_TOKEN")
        .when("branch == 'main'")
        .after(&["integration"]);

    // Deploy to prod (requires tag)
    p.task("deploy-prod")
        .run("./deploy.sh prod")
        .secret("DEPLOY_TOKEN")
        .when("tag matches 'v*'")
        .after(&["e2e"]);

    p.emit();
}

// Generated tasks:
//
// test-rust-1.70 ─┐
// test-rust-1.75 ─┼─> integration ─> e2e ─> publish
// test-rust-1.80 ─┤                       ─> deploy-prod
//                 └─> deploy-staging
