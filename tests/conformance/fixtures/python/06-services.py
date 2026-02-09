from sykli import Pipeline

p = Pipeline()

p.task("test").run("pytest") \
    .service("postgres:15", "db") \
    .service("redis:7", "cache")

p.emit()
