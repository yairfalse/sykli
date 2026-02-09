from sykli import Pipeline

p = Pipeline()

p.task("test-auth").run("pytest tests/auth/") \
    .inputs("src/auth/**/*.py", "tests/auth/**/*.py") \
    .covers("src/auth/*") \
    .intent("unit tests for auth module") \
    .set_criticality("high") \
    .on_fail("analyze") \
    .select_mode("smart")

p.emit()
