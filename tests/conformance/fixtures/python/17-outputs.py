from sykli import Pipeline

p = Pipeline()

p.task("build").run("make build") \
    .output("binary", "/out/app") \
    .output("checksum", "/out/sha256")

p.emit()
