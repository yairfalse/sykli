use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("build").run("make build").outputs(&["dist/app", "dist/lib"]);
    p.emit();
}
