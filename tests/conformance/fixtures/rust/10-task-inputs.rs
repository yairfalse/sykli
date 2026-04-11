use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("build").run("go build -o /out/app").output("binary", "/out/app");
    p.task("test").run("./app test").input_from("build", "binary", "/app");
    p.emit();
}
