#!/usr/bin/env python3
"""Pipeline with chain/parallel composition and conditions."""

from sykli import Pipeline, branch, tag

p = Pipeline()

lint = p.task("lint").run("ruff check .")

test_unit = p.task("test-unit").run("pytest tests/unit")
test_integration = p.task("test-integration").run("pytest tests/integration")
tests = p.parallel("tests", test_unit, test_integration)

build = p.task("build").run("python -m build")

deploy = p.task("deploy") \
    .run("./deploy.sh") \
    .when(branch("main") | tag("v*"))

p.chain(lint, tests, build, deploy)

p.emit()
