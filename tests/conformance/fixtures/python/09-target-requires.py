from sykli import Pipeline

p = Pipeline()

p.task("build").run("make build") \
    .target("docker") \
    .requires("gpu", "high-memory")

p.emit()
