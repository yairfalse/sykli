# Sykli Python SDK

AI-native CI pipeline SDK for Python. Define pipelines in Python, run them anywhere.

## Install

```bash
pip install sykli
```

## Quick Start

Create `sykli.py`:

```python
from sykli import Pipeline

p = Pipeline()
p.task("lint").run("ruff check .")
p.task("test").run("pytest").after("lint")
p.task("build").run("python -m build").after("test")
p.emit()
```

Run:

```bash
sykli run
```

## Features

- Fluent builder API
- Conditions with `|` and `&` operators
- Container support with mounts and services
- Pipeline combinators: `chain`, `parallel`, `matrix`
- AI-native metadata: `covers`, `intent`, `criticality`
- Capability-based dependencies: `provides` / `needs`
- Gates (approval points)
- Reusable templates
- Language presets
- Zero runtime dependencies (stdlib only)

See `examples/` for more.
