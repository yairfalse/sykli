#!/usr/bin/env python3
"""Basic pipeline: lint → test → build."""

from sykli import Pipeline

p = Pipeline()

p.task("lint").run("ruff check .")
p.task("test").run("pytest").after("lint")
p.task("build").run("python -m build").after("test")

p.emit()
