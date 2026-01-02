//! Example 06: Matrix Builds & Services
//!
//! This example demonstrates:
//! - `.matrix()` for testing across configurations
//! - Service containers with `.service()`
//! - `.retry()` and `.timeout()` for resilience
//! - Secrets with `.secret()` and `.secret_from()`
//!
//! Run with: sykli run

use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    let src = p.dir(".");

    // === MATRIX BUILDS ===

    // Test across multiple Rust versions
    // Creates: test-1.70, test-1.75, test-1.80
    for version in &["1.70", "1.75", "1.80"] {
        p.task(&format!("test-rust-{}", version))
            .container(&format!("rust:{}", version))
            .mount(&src, "/src")
            .mount_cache(&p.cache(&format!("cargo-{}", version)), "/usr/local/cargo/registry")
            .workdir("/src")
            .run("cargo test");
    }

    // === SERVICE CONTAINERS ===

    // Integration tests with database and cache services
    p.task("integration")
        .container("rust:1.75")
        .mount(&src, "/src")
        .workdir("/src")
        .service("postgres:15", "db")       // Accessible as hostname "db"
        .service("redis:7", "cache")        // Accessible as hostname "cache"
        .env("DATABASE_URL", "postgres://postgres:postgres@db:5432/test?sslmode=disable")
        .env("REDIS_URL", "redis://cache:6379")
        .run("cargo test --features integration")
        .timeout(300)  // 5 minute timeout
        .after(&["test-rust-1.70", "test-rust-1.75", "test-rust-1.80"]);

    // === RETRY & TIMEOUT ===

    // Flaky tests with retry
    p.task("e2e")
        .container("playwright/playwright:latest")
        .mount(&src, "/src")
        .workdir("/src")
        .run("npm run e2e")
        .retry(3)       // Retry up to 3 times
        .timeout(600)   // 10 minute timeout
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
