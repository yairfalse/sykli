use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("compile").run("go build -o /out/app ./cmd/server").provides("binary", Some("/out/app"));
    p.task("migrate").run("dbmate up").provides("db-ready", None);
    p.task("integration-test").run("go test -tags=integration ./...").needs(&["binary", "db-ready"]).timeout(300);
    p.emit();
}
