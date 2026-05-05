from sykli import Pipeline

p = Pipeline()

p.task("build").run("make build") \
    .requires("gpu", "high-memory")

p.emit()
