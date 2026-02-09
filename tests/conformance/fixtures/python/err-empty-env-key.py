from sykli import Pipeline

p = Pipeline()

# Empty env key should fail
p.task("test").run("echo test").env("", "value")

p.emit()
