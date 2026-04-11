use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("build").run("make build").output("binary", "/out/app").output("checksum", "/out/sha256");
    p.emit();
}
