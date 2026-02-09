from sykli import Pipeline

p = Pipeline()

p.task("test").run("go test ./...") \
    .matrix("os", "linux", "darwin") \
    .matrix("arch", "amd64", "arm64")

p.emit()
