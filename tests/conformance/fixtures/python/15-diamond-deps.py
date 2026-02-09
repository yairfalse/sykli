from sykli import Pipeline

p = Pipeline()

p.task("A").run("echo A")
p.task("B").run("echo B").after("A")
p.task("C").run("echo C").after("A")
p.task("D").run("echo D").after("B", "C")

p.emit()
