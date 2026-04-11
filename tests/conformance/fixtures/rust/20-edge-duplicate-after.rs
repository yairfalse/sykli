use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("build").run("make build");
    p.task("test").run("go test").after(&["build"]);
    p.task("deploy").run("./deploy.sh").after(&["build", "test"]);
    p.emit();
}
