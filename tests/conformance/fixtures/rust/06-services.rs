use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("test").run("pytest").service("postgres:15", "db").service("redis:7", "cache");
    p.emit();
}
