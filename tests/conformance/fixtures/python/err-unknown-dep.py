from sykli import Pipeline

p = Pipeline()

p.task("test").run("go test ./...").after("nonexistent")

p.emit()
