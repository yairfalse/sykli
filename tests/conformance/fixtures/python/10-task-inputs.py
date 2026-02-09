from sykli import Pipeline

p = Pipeline()

p.task("build").run("go build -o /out/app") \
    .output("binary", "/out/app")

p.task("test").run("./app test") \
    .input_from("build", "binary", "/app")

p.emit()
