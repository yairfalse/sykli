use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("hello").run("echo hello");
    p.emit();
}
