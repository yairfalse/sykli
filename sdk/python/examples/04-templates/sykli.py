#!/usr/bin/env python3
"""Pipeline with reusable templates."""

from sykli import Pipeline

p = Pipeline()
src = p.dir(".")
cache = p.cache("pip")

python = p.template("python") \
    .container("python:3.12") \
    .mount(src, "/app") \
    .mount_cache(cache, "/root/.cache/pip") \
    .workdir("/app")

p.task("lint") \
    .from_template(python) \
    .run("ruff check .")

p.task("test") \
    .from_template(python) \
    .run("pytest") \
    .after("lint")

p.task("build") \
    .from_template(python) \
    .run("python -m build") \
    .after("test")

p.emit()
