from sykli import Pipeline

p = Pipeline()

p.task("test").run("npm test") \
    .container("node:20") \
    .workdir("/app") \
    .env("NODE_ENV", "test") \
    .env("CI", "true") \
    .retry(3) \
    .timeout(300) \
    .secrets("NPM_TOKEN", "GH_TOKEN") \
    .when("branch:main")

p.emit()
