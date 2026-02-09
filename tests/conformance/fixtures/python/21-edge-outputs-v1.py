from sykli import Pipeline

p = Pipeline()

# v1-style outputs (positional, auto-named)
p.task("build").run("make build").outputs("dist/app", "dist/lib")

p.emit()
