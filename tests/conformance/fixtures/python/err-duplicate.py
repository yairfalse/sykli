from sykli import Pipeline

p = Pipeline()

p.task("test").run("go test ./...")
p.task("test").run("go test -race ./...")

p.emit()
