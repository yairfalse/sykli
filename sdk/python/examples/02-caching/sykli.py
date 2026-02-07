#!/usr/bin/env python3
"""Pipeline with input-based caching."""

from sykli import Pipeline

p = Pipeline()

p.task("lint") \
    .run("ruff check .") \
    .inputs("**/*.py", "pyproject.toml")

p.task("test") \
    .run("pytest") \
    .inputs("**/*.py", "pyproject.toml") \
    .after("lint")

p.emit()
