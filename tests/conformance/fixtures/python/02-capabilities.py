from sykli import Pipeline

p = Pipeline()

p.task("compile").run("go build -o /out/app ./cmd/server") \
    .provides("binary", "/out/app")

p.task("migrate").run("dbmate up") \
    .provides("db-ready")

p.task("integration-test").run("go test -tags=integration ./...") \
    .needs("binary", "db-ready").timeout(300)

p.emit()
