use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("test");
    p.emit();
}
