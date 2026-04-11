use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("test").run("npm test")
        .container("node:20")
        .workdir("/app")
        .env("CI", "true")
        .env("NODE_ENV", "test")
        .retry(3)
        .timeout(300)
        .secrets(&["NPM_TOKEN", "GH_TOKEN"])
        .when("branch:main");
    p.emit();
}
