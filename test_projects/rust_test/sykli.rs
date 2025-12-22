// Test all Rust SDK features
use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    // Basic task
    p.task("echo")
        .run("echo 'Hello from Rust SDK'");

    // Task with inputs (caching)
    p.task("cached")
        .run("echo 'This should cache'")
        .inputs(&["sykli.rs"]);

    // Task with dependency
    p.task("dependent")
        .run("echo 'Runs after echo'")
        .after(&["echo"]);

    // Task with retry (will succeed on first try)
    p.task("retry_test")
        .run("echo 'Testing retry'")
        .retry(2);

    // Task with timeout
    p.task("timeout_test")
        .run("echo 'Quick task'")
        .timeout(30);

    // Task with condition (should run - we're not in CI)
    p.task("conditional")
        .run("echo 'Condition: not CI'")
        .when("ci != true");

    // Task that depends on multiple
    p.task("final")
        .run("echo 'All features work!'")
        .after(&["cached", "dependent", "retry_test", "timeout_test", "conditional"]);

    p.emit();
}
