from sykli import Pipeline

p = Pipeline()

p.task("build").run("go build ./...").task_type("build")
p.task("test").run("go test ./...").task_type("test").after("build")

p.emit()
