# Sykli Python SDK

CI pipelines defined in Python instead of YAML. Zero runtime dependencies (stdlib only).

```python
from sykli import Pipeline

p = Pipeline()
p.task("lint").run("ruff check .")
p.task("test").run("pytest").after("lint")
p.task("build").run("python -m build").after("test")
p.emit()
```

## Install

```bash
pip install sykli
```

Requires **Python 3.12+** (the SDK uses `Self` and PEP 604 union types).

## Quick Start

Create `sykli.py` in your project root:

```python
from sykli import Pipeline

p = Pipeline()

p.task("lint").run("ruff check .")
p.task("test").run("pytest --cov").after("lint")
p.task("build").run("python -m build").after("test")

p.emit()
```

Run:

```bash
sykli run
```

## Tasks and dependencies

```python
p.task("test").run("pytest")
p.task("build").run("python -m build").after("test")
p.task("deploy").run("./deploy.sh").after("build", "lint")
```

Independent tasks run in parallel. `after()` declares dependencies.

## Caching, outputs, artifacts

```python
p.task("test") \
    .run("pytest") \
    .inputs("**/*.py", "pyproject.toml")  # cache key invalidates if these change

p.task("build") \
    .run("python -m build") \
    .output("wheel", "dist/")              # named artifact

p.task("publish") \
    .input_from("build", "wheel", "./dist") \  # auto-depends on "build"
    .run("twine upload dist/*")
```

## Conditions (with `|` and `&`)

Conditions are first-class values. Combine with Python operators:

```python
from sykli import branch, tag, has_tag, event, in_ci, not_

p.task("deploy") \
    .run("./deploy.sh") \
    .when_cond(branch("main"))

# OR — `|` operator
p.task("notify") \
    .run("./notify.sh") \
    .when_cond(branch("main") | has_tag())

# AND — `&` operator
p.task("publish") \
    .run("twine upload dist/*") \
    .when_cond(branch("main") & tag("v*"))

# Negation
p.task("preview") \
    .run("./preview.sh") \
    .when_cond(not_(branch("wip/*")))
```

Plain string conditions also work: `.when("branch == 'main'")`.

## AI-native metadata

Tasks can declare semantic information that downstream agents and the engine use for smarter selection, failure analysis, and prioritization:

```python
p.task("test") \
    .run("pytest") \
    .covers("src/**/*.py") \      # which files this task validates
    .intent("unit tests for all packages") \
    .critical()                    # shorthand for set_criticality("high")

p.task("smoke") \
    .run("./smoke.sh") \
    .set_criticality("low") \
    .on_fail("retry") \            # "analyze" | "retry" | "skip"
    .select_mode("smart")          # "smart" | "always" | "manual"
```

## Capability-based dependencies

`provides` / `needs` declare cross-task contracts beyond simple `after` ordering:

```python
p.task("setup-db") \
    .run("./create-db.sh") \
    .provides("database", value="postgres://localhost:5432/test")

p.task("integration-test") \
    .run("pytest tests/integration") \
    .needs("database")             # implicitly depends on whoever provides "database"
```

## Gates

A gate is a task with no command — execution pauses until approval:

```python
p.gate("approve-prod") \
    .gate_strategy("env") \
    .gate_env_var("DEPLOY_APPROVED") \
    .gate_message("Approve production deploy?") \
    .gate_timeout(1800) \
    .after("test")

p.task("deploy-prod") \
    .run("./deploy.sh") \
    .after("approve-prod")
```

Strategies: `"prompt"` (interactive), `"env"` (env var must be set), `"file"`, `"webhook"`.

## Containers, services, secrets

```python
src = p.dir(".")
pip_cache = p.cache("pip")

p.task("integration") \
    .container("python:3.12") \
    .mount(src, "/app") \
    .mount_cache(pip_cache, "/root/.cache/pip") \
    .workdir("/app") \
    .service("postgres:15", "db") \
    .env("DATABASE_URL", "postgres://postgres@db:5432/test") \
    .secret("PYPI_TOKEN") \
    .run("pytest tests/integration")
```

## Composition: parallel, chain, matrix

```python
p.task("lint").run("ruff check .")
p.task("typecheck").run("mypy src/")
p.task("test").run("pytest")

checks = p.parallel("checks", ["lint", "typecheck", "test"])

p.task("build").run("python -m build").after_group(checks)

# matrix: one task per Python version
p.matrix("py-test", ["3.12", "3.13"], lambda v:
    p.task(f"test-py{v}")
        .container(f"python:{v}")
        .run("pytest")
)
```

## Validation

The SDK fails fast with a structured `ValidationError`:

```python
from sykli import ValidationError

try:
    p.emit()
except ValidationError as e:
    print(e.code)        # MISSING_COMMAND | UNKNOWN_DEPENDENCY | CYCLE_DETECTED | ...
    print(e.suggestion)  # e.g., 'did you mean "build"?' (Jaro-Winkler)
```

Cycle detection, duplicate names, missing commands, and unknown dependencies are all caught before any task runs.

## Development

Property-based tests use [Hypothesis](https://hypothesis.readthedocs.io/). Install with the `dev` extra:

```bash
pip install -e ".[dev]"
pytest
```

`pyproject.toml` declares the dev extras (`pytest>=8.0`, `hypothesis>=6.0`).

## Reference

Full API documentation, including every method on `Task`, `Pipeline`, `Template`, `Condition`, and `K8sOptions`, lives in [REFERENCE.md](./REFERENCE.md).

## Examples

See [examples/](./examples/) for runnable pipelines covering basics, caching, containers, templates, composition, and matrix builds.

## License

MIT
