from sykli import Pipeline

p = Pipeline()

p.task("test").run("go test ./...")
p.review("review-code") \
    .primitive("lint") \
    .agent("claude") \
    .context("src/**/*.go") \
    .after("test") \
    .deterministic(True)

p.emit()
