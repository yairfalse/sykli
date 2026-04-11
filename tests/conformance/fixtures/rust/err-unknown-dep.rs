use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("test").run("go test ./...").after(&["nonexistent"]);
    p.emit();
}
