from sykli import Pipeline

p = Pipeline()

p.task("hello").run("echo hello")

p.emit()
