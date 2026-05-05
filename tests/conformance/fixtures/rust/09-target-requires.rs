use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("build").run("make build").requires(&["gpu", "high-memory"]);
    p.emit();
}
