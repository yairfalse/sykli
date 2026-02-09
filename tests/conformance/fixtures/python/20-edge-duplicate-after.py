from sykli import Pipeline

p = Pipeline()

p.task("build").run("make build")

# Duplicate after calls should be deduplicated
p.task("test").run("go test").after("build").after("build")

p.task("deploy").run("./deploy.sh").after("build", "test", "build", "test")

p.emit()
