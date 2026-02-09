use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();

    p.task("lint").run("echo lint ok");
    p.task("test").run("echo test ok");
    p.task("build").run("echo build ok").after(&["lint", "test"]);

    p.emit();
}
