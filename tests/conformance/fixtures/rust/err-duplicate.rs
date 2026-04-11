use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("test").run("go test ./...");
    p.task("test").run("go test -race ./...");
    p.emit();
}
