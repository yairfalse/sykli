# Sykli Python SDK - API Reference

Complete API documentation for the Sykli Python SDK.

## Table of Contents

- [Pipeline](#pipeline)
- [Task](#task)
- [Template](#template)
- [Resources](#resources)
- [Composition](#composition)
- [Conditions](#conditions)
- [Secrets](#secrets)
- [Kubernetes](#kubernetes)
- [Language Presets](#language-presets)

---

## Pipeline

### Constructor

```python
Pipeline(*, k8s_defaults: K8sOptions | None = None)
```

Creates a new pipeline with optional configuration.

**Example:**
```python
from sykli import Pipeline, K8sOptions

# Basic pipeline
p = Pipeline()

# With K8s defaults
p = Pipeline(k8s_defaults=K8sOptions(memory="512Mi", cpu="500m"))
```

### task

```python
def task(self, name: str) -> Task
```

Creates a new task. Raises `ValueError` if name is empty or duplicate.

### gate

```python
def gate(self, name: str) -> Task
```

Creates a gate task (approval/manual step). Returns a `Task` with gate defaults (`strategy="prompt"`, `timeout=3600`).

### template

```python
def template(self, name: str) -> Template
```

Creates a reusable task template.

### dir

```python
def dir(self, path: str) -> Directory
```

Creates a directory resource for mounting into containers. Returns existing instance if path was already registered (deduplicates).

### cache

```python
def cache(self, name: str) -> CacheVolume
```

Creates a named cache volume for persisting data between runs. Returns existing instance if name was already registered (deduplicates).

### emit

```python
def emit(self) -> NoReturn
```

Outputs the pipeline as JSON if `--emit` flag is present, then calls `sys.exit(0)`. Call this at the end of your `sykli.py`.

### emit_to

```python
def emit_to(self, writer: IO[str]) -> None
```

Validates and writes the pipeline JSON to the given writer.

### to_dict

```python
def to_dict(self) -> dict
```

Validates and returns the pipeline as a dict. Useful for testing.

### validate

```python
def validate(self) -> None
```

Validates the pipeline. Raises `ValidationError` on problems (missing commands, unknown dependencies, cycles, invalid K8s resources).

### explain

```python
def explain(self, ctx: ExplainContext | None = None) -> None
```

Prints a human-readable execution plan to stderr without running anything.

### explain_to

```python
def explain_to(self, writer: IO[str], ctx: ExplainContext | None = None) -> None
```

Prints a human-readable execution plan to a writer.

---

## Task

All setter methods return `self` for fluent chaining.

### run

```python
def run(self, cmd: str) -> Self
```

Sets the command for this task. **Required** for non-gate tasks.

### container

```python
def container(self, image: str) -> Self
```

Sets the container image for this task.

### mount

```python
def mount(self, directory: Directory, path: str) -> Self
```

Mounts a directory into the container. Path must be absolute.

### mount_cache

```python
def mount_cache(self, cache: CacheVolume, path: str) -> Self
```

Mounts a cache volume into the container. Path must be absolute.

### mount_cwd

```python
def mount_cwd(self) -> Self
```

Convenience method: mounts current directory to `/work` and sets workdir.

### mount_cwd_at

```python
def mount_cwd_at(self, path: str) -> Self
```

Mounts current directory to a custom path and sets workdir.

### workdir

```python
def workdir(self, path: str) -> Self
```

Sets the working directory inside the container.

### env

```python
def env(self, key: str, val: str) -> Self
```

Sets an environment variable.

### service

```python
def service(self, image: str, name: str) -> Self
```

Adds a service container (database, cache) that runs alongside this task.

### inputs

```python
def inputs(self, *patterns: str) -> Self
```

Sets input file patterns for caching. Supports glob patterns (`**/*.py`).

### output

```python
def output(self, name: str, path: str) -> Self
```

Declares a named output artifact.

### outputs

```python
def outputs(self, *paths: str) -> Self
```

Declares multiple output artifacts (auto-named).

### input_from

```python
def input_from(self, task: str, output_name: str, dest: str) -> Self
```

Consumes an artifact from another task's output. Automatically adds dependency.

### after

```python
def after(self, *tasks: str) -> Self
```

Sets dependencies - this task runs after the named tasks.

### after_group

```python
def after_group(self, *groups: TaskGroup) -> Self
```

Depends on all tasks in the given groups.

### from_template

```python
def from_template(self, tmpl: Template) -> Self
```

Applies a template's configuration. Task settings override template settings.

### when

```python
def when(self, cond: str | Condition) -> Self
```

Sets a condition for when this task should run. Accepts a string expression or a type-safe `Condition`.

### secret

```python
def secret(self, name: str) -> Self
```

Declares that this task requires a secret.

### secrets

```python
def secrets(self, *names: str) -> Self
```

Declares multiple required secrets.

### secret_from

```python
def secret_from(self, name: str, ref: SecretRef) -> Self
```

Declares a typed secret reference with explicit source.

### matrix

```python
def matrix(self, key: str, *values: str) -> Self
```

Adds a matrix dimension. Creates task variants for each value.

### retry

```python
def retry(self, n: int) -> Self
```

Sets the number of retry attempts on failure.

### timeout

```python
def timeout(self, secs: int) -> Self
```

Sets the task timeout in seconds. Must be positive.

### target

```python
def target(self, name: str) -> Self
```

Deprecated no-op. It no longer affects emitted pipeline JSON. Use concrete execution requirements such as `container`, mounts, `k8s`, services, workdir, and env instead.

### k8s

```python
def k8s(self, opts: K8sOptions) -> Self
```

Adds Kubernetes-specific options.

### k8s_raw

```python
def k8s_raw(self, raw: str) -> Self
```

Sets raw JSON for advanced K8s options (escape hatch).

### requires

```python
def requires(self, *labels: str) -> Self
```

Sets required node profile labels for mesh placement.

### covers

```python
def covers(self, *patterns: str) -> Self
```

Declares file patterns this task covers (semantic metadata for AI analysis).

### intent

```python
def intent(self, desc: str) -> Self
```

Describes the purpose of this task for AI analysis.

### critical

```python
def critical(self) -> Self
```

Marks this task as high criticality.

### set_criticality

```python
def set_criticality(self, level: str) -> Self
```

Sets criticality level. Must be one of: `"high"`, `"medium"`, `"low"`.

### on_fail

```python
def on_fail(self, action: str) -> Self
```

Sets the AI hook action on failure. Must be one of: `"analyze"`, `"retry"`, `"skip"`.

### select_mode

```python
def select_mode(self, mode: str) -> Self
```

Sets the task selection mode. Must be one of: `"smart"`, `"always"`, `"manual"`.

### smart

```python
def smart(self) -> Self
```

Shorthand for `select_mode("smart")`.

### provides

```python
def provides(self, name: str, value: str | None = None) -> Self
```

Declares a capability this task provides.

### needs

```python
def needs(self, *names: str) -> Self
```

Declares capabilities this task requires.

### verify

```python
def verify(self, mode: str) -> Self
```

Sets cross-platform verification mode. Must be one of: `"cross_platform"`, `"always"`, `"never"`.

### name

```python
@property
def name(self) -> str
```

Returns the task's name (for use in dependencies).

### Gate Methods

```python
def gate_strategy(self, s: str) -> Self       # "prompt", "env", "file", "webhook"
def gate_message(self, msg: str) -> Self       # Human-readable approval message
def gate_timeout(self, secs: int) -> Self      # Timeout in seconds (must be positive)
def gate_env_var(self, var: str) -> Self        # Env var for "env" strategy
def gate_file_path(self, path: str) -> Self    # File path for "file" strategy
```

---

## Template

Templates provide reusable task configuration.

### container

```python
def container(self, image: str) -> Self
```

### workdir

```python
def workdir(self, path: str) -> Self
```

### env

```python
def env(self, key: str, val: str) -> Self
```

### mount

```python
def mount(self, directory: Directory, path: str) -> Self
```

### mount_cache

```python
def mount_cache(self, cache: CacheVolume, path: str) -> Self
```

**Example:**
```python
p = Pipeline()
src = p.dir(".")
cache = p.cache("pip")

base = p.template("python") \
    .container("python:3.12") \
    .mount(src, "/src") \
    .mount_cache(cache, "/root/.cache/pip") \
    .workdir("/src")

p.task("test").from_template(base).run("pytest")
p.task("lint").from_template(base).run("ruff check .")
```

---

## Resources

### Directory

```python
class Directory:
    def __init__(self, path: str) -> None
```

Represents a host directory. Created via `Pipeline.dir()`.

**Properties:**
- `id -> str` - Returns unique identifier (`"src:<path>"`)
- `path -> str` - Returns the directory path

**Methods:**
- `glob(*patterns: str) -> Self` - Filter by glob patterns

### CacheVolume

```python
class CacheVolume:
    def __init__(self, name: str) -> None
```

Represents a named persistent cache. Created via `Pipeline.cache()`.

**Properties:**
- `id -> str` - Returns cache name
- `cache_name -> str` - Returns cache name

---

## Composition

### chain

```python
def chain(self, *items: Task | TaskGroup) -> TaskGroup
```

Creates a sequential dependency chain. Each item depends on the previous.

**Example:**
```python
lint = p.task("lint").run("ruff check .")
test = p.task("test").run("pytest")
deploy = p.task("deploy").run("./deploy.sh")

p.chain(lint, test, deploy)
```

### parallel

```python
def parallel(self, name: str, *tasks: Task) -> TaskGroup
```

Creates a group of tasks that run concurrently.

**Example:**
```python
lint = p.task("lint").run("ruff check .")
typecheck = p.task("typecheck").run("mypy .")
checks = p.parallel("checks", lint, typecheck)

p.task("test").run("pytest").after_group(checks)
```

### matrix

```python
def matrix(
    self,
    name: str,
    values: Sequence[str],
    fn: Callable[[str], Task],
) -> TaskGroup
```

Creates tasks for each value using a generator function.

**Example:**
```python
versions = p.matrix("test-py", ["3.10", "3.11", "3.12"], lambda v:
    p.task(f"test-{v}")
        .container(f"python:{v}")
        .mount_cwd()
        .run("pytest")
)
```

### matrix_map

```python
def matrix_map(
    self,
    name: str,
    values: dict[str, str],
    fn: Callable[[str, str], Task],
) -> TaskGroup
```

Creates tasks for each key-value pair.

**Example:**
```python
targets = p.matrix_map("build", {"linux": "x86_64", "mac": "arm64"}, lambda k, v:
    p.task(f"build-{k}").run(f"./build.sh --arch={v}")
)
```

### TaskGroup

```python
class TaskGroup:
    def __init__(self, name: str, task_names: list[str]) -> None
```

A group of tasks created by `parallel()`, `matrix()`, or `chain()`.

**Properties:**
- `name -> str` - Group name
- `task_names -> list[str]` - Names of all tasks in group
- `last_tasks -> list[str]` - Task names at the end of the group (for `after_group` chaining)

---

## Conditions

### String Conditions

```python
t.when("branch == 'main'")
t.when("tag != ''")
t.when("event == 'push'")
t.when("ci == true")
```

### Type-Safe Conditions

```python
# Builders
branch(pattern: str) -> Condition
tag(pattern: str) -> Condition
has_tag() -> Condition
event(type_: str) -> Condition
in_ci() -> Condition
not_(c: Condition) -> Condition

# Combinators (operator overloading)
c1 | c2    # OR  (also: c1.or_(c2))
c1 & c2    # AND (also: c1.and_(c2))
```

**Examples:**
```python
from sykli import branch, tag, event, in_ci, not_

t.when(branch("main"))
t.when(tag("v*"))
t.when(branch("main") | tag("v*"))
t.when(not_(branch("wip/*")) & event("push"))
t.when(in_ci())
```

---

## Secrets

### from_env

```python
def from_env(name: str, key: str) -> SecretRef
```

Creates a secret reference from an environment variable.

### from_file

```python
def from_file(name: str, key: str) -> SecretRef
```

Creates a secret reference from a file.

### from_vault

```python
def from_vault(name: str, key: str) -> SecretRef
```

Creates a secret reference from HashiCorp Vault.

### SecretRef

```python
@dataclass(frozen=True)
class SecretRef:
    name: str
    source: str  # "env", "file", "vault"
    key: str
```

**Example:**
```python
from sykli import from_env, from_vault

p.task("deploy") \
    .run("./deploy.sh") \
    .secret("API_KEY") \
    .secret_from("DB_PASSWORD", from_env("DB_PASSWORD", "DB_PASS")) \
    .secret_from("VAULT_TOKEN", from_vault("VAULT_TOKEN", "secret/data/ci#token"))
```

---

## Kubernetes

### K8sOptions

```python
@dataclass(frozen=True)
class K8sOptions:
    memory: str = ""    # e.g., "512Mi", "4Gi"
    cpu: str = ""       # e.g., "500m", "2", "1.5"
    gpu: int = 0        # Number of GPUs
    raw: str = ""       # Raw JSON for advanced options (escape hatch)
```

**Example:**
```python
from sykli import Pipeline, K8sOptions

p = Pipeline(k8s_defaults=K8sOptions(memory="512Mi", cpu="500m"))

p.task("train") \
    .run("python train.py") \
    .k8s(K8sOptions(memory="16Gi", cpu="4", gpu=1))

# Raw K8s JSON escape hatch
p.task("special") \
    .run("./run.sh") \
    .k8s_raw('{"nodeSelector": {"gpu": "a100"}}')
```

---

## Language Presets

### PythonPreset

```python
p.python().test()        # pytest (inputs: **/*.py, pyproject.toml)
p.python().lint()        # ruff check . (inputs: **/*.py, pyproject.toml)
p.python().typecheck()   # mypy . (inputs: **/*.py, pyproject.toml)
p.python().build()       # python -m build (inputs: **/*.py, pyproject.toml)
```

Each preset method returns a `Task` that can be further configured:

```python
p = Pipeline()
p.python().test().container("python:3.12").mount_cwd()
p.python().lint().after("test")
p.emit()
```

---

## Other Types

### ValidationError

```python
class ValidationError(Exception):
    def __init__(self, code: str, message: str, task: str = "", suggestion: str = "") -> None
```

Structured validation error raised by `Pipeline.validate()`, `Pipeline.emit()`, `Pipeline.emit_to()`, and `Pipeline.to_dict()`.

Error codes: `MISSING_COMMAND`, `UNKNOWN_DEPENDENCY`, `CYCLE_DETECTED`, `INVALID_K8S`.

### ExplainContext

```python
@dataclass
class ExplainContext:
    branch: str = ""
    tag: str = ""
    event: str = ""
    ci: bool = False
```

Runtime context for condition evaluation in explain mode.

### Enums

```python
class Criticality(str, enum.Enum):
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"

class OnFailAction(str, enum.Enum):
    ANALYZE = "analyze"
    RETRY = "retry"
    SKIP = "skip"

class SelectMode(str, enum.Enum):
    SMART = "smart"
    ALWAYS = "always"
    MANUAL = "manual"
```
