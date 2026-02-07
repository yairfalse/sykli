#!/usr/bin/env python3
"""Pipeline with containers, mounts, and services."""

from sykli import Pipeline

p = Pipeline()
src = p.dir(".")
cache = p.cache("pip")

p.task("test") \
    .container("python:3.12") \
    .mount(src, "/src") \
    .mount_cache(cache, "/root/.cache/pip") \
    .workdir("/src") \
    .run("pip install -e '.[dev]' && pytest") \
    .service("postgres:16", "db") \
    .env("DATABASE_URL", "postgresql://db:5432/test")

p.emit()
