from sykli import Pipeline

p = Pipeline()

p.task("A").run("echo A").after("B")
p.task("B").run("echo B").after("A")

p.emit()
