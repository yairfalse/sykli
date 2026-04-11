use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("build").run("make build").target("docker").requires(&["gpu", "high-memory"]);
    p.emit();
}
