use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("A").run("echo A").after(&["B"]);
    p.task("B").run("echo B").after(&["A"]);
    p.emit();
}
