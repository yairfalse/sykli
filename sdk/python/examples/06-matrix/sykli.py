#!/usr/bin/env python3
"""Pipeline with matrix builds across Python versions."""

from sykli import Pipeline

p = Pipeline()

p.task("lint").run("ruff check .")

g = p.matrix(
    "test",
    ["3.11", "3.12", "3.13"],
    lambda v: p.task(f"test-py{v}")
        .run(f"python{v} -m pytest")
        .after("lint"),
)

p.task("build") \
    .run("python -m build") \
    .after_group(g)

p.emit()
