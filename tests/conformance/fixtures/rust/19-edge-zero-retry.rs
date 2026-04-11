use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("test").run("echo test");
    p.task("flaky").run("echo flaky").retry(2);
    p.emit();
}
