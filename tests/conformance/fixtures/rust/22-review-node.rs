use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    p.task("test").run("go test ./...");
    p.review("review-code")
        .primitive("lint")
        .agent("claude")
        .context(&["src/**/*.go"])
        .after(&["test"])
        .deterministic(true);

    p.emit();
}
