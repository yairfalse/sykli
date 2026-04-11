use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("build").run("make build").provides("artifact", None);
    p.task("migrate").run("dbmate up").provides("db-ready", None);
    p.task("package").run("docker build").provides("image", Some("myapp:latest")).after(&["build"]);
    p.emit();
}
