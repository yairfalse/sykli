use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    let _ = p.task("test").run("echo hello").container("alpine:latest");
    let _ = p.task("build").run("echo build").after(&["test"]);
    p.emit();
}
