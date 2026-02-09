"""Sykli Python SDK — fluent API for defining AI-native CI pipelines.

Simple usage::

    from sykli import Pipeline

    p = Pipeline()
    p.task("test").run("pytest")
    p.task("build").run("python -m build").after("test")
    p.emit()

With containers and caching (v2)::

    from sykli import Pipeline

    p = Pipeline()
    src = p.dir(".")
    cache = p.cache("pip")

    p.task("test") \\
        .container("python:3.12") \\
        .mount(src, "/src") \\
        .mount_cache(cache, "/root/.cache/pip") \\
        .workdir("/src") \\
        .run("pytest")
    p.emit()

With conditions::

    from sykli import Pipeline, branch, tag

    p = Pipeline()
    p.task("deploy").run("./deploy.sh").when(branch("main") | tag("v*"))
    p.emit()
"""

from __future__ import annotations

import enum
import json
import logging
import os
import sys
from dataclasses import dataclass, field
from typing import (
    IO,
    Any,
    Callable,
    NoReturn,
    Self,
    Sequence,
)

__all__ = [
    # Core
    "Pipeline",
    "Task",
    "TaskGroup",
    # Resources
    "Directory",
    "CacheVolume",
    "Template",
    # Conditions
    "Condition",
    "branch",
    "tag",
    "has_tag",
    "event",
    "in_ci",
    "not_",
    # Secrets
    "SecretRef",
    "from_env",
    "from_file",
    "from_vault",
    # Types
    "K8sOptions",
    "ValidationError",
    "ExplainContext",
    # Presets
    "PythonPreset",
]

log = logging.getLogger("sykli")


# =============================================================================
# VALUE OBJECTS
# =============================================================================


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


@dataclass(frozen=True)
class SecretRef:
    """Typed secret reference with explicit source."""

    name: str
    source: str  # "env", "file", "vault"
    key: str


def from_env(name: str, key: str) -> SecretRef:
    """Create a secret reference from an environment variable."""
    return SecretRef(name=name, source="env", key=key)


def from_file(name: str, key: str) -> SecretRef:
    """Create a secret reference from a file."""
    return SecretRef(name=name, source="file", key=key)


def from_vault(name: str, key: str) -> SecretRef:
    """Create a secret reference from a vault."""
    return SecretRef(name=name, source="vault", key=key)


@dataclass(frozen=True)
class K8sOptions:
    """Kubernetes resource options for a task."""

    memory: str = ""
    cpu: str = ""
    gpu: int = 0
    raw: str = ""


@dataclass
class ExplainContext:
    """Runtime context for condition evaluation in explain mode."""

    branch: str = ""
    tag: str = ""
    event: str = ""
    ci: bool = False


class ValidationError(Exception):
    """Structured validation error raised at emit time."""

    def __init__(self, code: str, message: str, task: str = "", suggestion: str = "") -> None:
        self.code = code
        self.task = task
        self.suggestion = suggestion
        super().__init__(message)


# =============================================================================
# CONDITIONS
# =============================================================================


class Condition:
    """Type-safe condition expression with operator overloading.

    Supports ``|`` (OR) and ``&`` (AND) operators::

        branch("main") | tag("v*")
        branch("main") & event("push")
    """

    __slots__ = ("_expr",)

    def __init__(self, expr: str) -> None:
        self._expr = expr

    def or_(self, other: Condition) -> Condition:
        return Condition(f"({self._expr}) || ({other._expr})")

    def and_(self, other: Condition) -> Condition:
        return Condition(f"({self._expr}) && ({other._expr})")

    def __or__(self, other: Condition) -> Condition:
        return self.or_(other)

    def __and__(self, other: Condition) -> Condition:
        return self.and_(other)

    def __str__(self) -> str:
        return self._expr

    def __repr__(self) -> str:
        return f"Condition({self._expr!r})"

    def __eq__(self, other: object) -> bool:
        if isinstance(other, Condition):
            return self._expr == other._expr
        return NotImplemented

    def __hash__(self) -> int:
        return hash(self._expr)


def branch(pattern: str) -> Condition:
    """Match a branch name or glob pattern."""
    if "*" in pattern:
        return Condition(f"branch matches '{pattern}'")
    return Condition(f"branch == '{pattern}'")


def tag(pattern: str) -> Condition:
    """Match a tag name or glob pattern."""
    if "*" in pattern:
        return Condition(f"tag matches '{pattern}'")
    return Condition(f"tag == '{pattern}'")


def has_tag() -> Condition:
    """Match when any tag is present."""
    return Condition("tag != ''")


def event(type_: str) -> Condition:
    """Match a specific event type."""
    return Condition(f"event == '{type_}'")


def in_ci() -> Condition:
    """Match when running in CI."""
    return Condition("ci == true")


def not_(c: Condition) -> Condition:
    """Negate a condition."""
    return Condition(f"!({c})")


# =============================================================================
# RESOURCES
# =============================================================================


class Directory:
    """Source directory resource for container mounts."""

    __slots__ = ("_path", "_globs")

    def __init__(self, path: str) -> None:
        self._path = path
        self._globs: list[str] = []

    def glob(self, *patterns: str) -> Self:
        self._globs.extend(patterns)
        return self

    @property
    def id(self) -> str:
        return f"src:{self._path}"

    @property
    def path(self) -> str:
        return self._path

    def _to_resource(self) -> dict[str, Any]:
        d: dict[str, Any] = {"type": "directory", "path": self._path}
        if self._globs:
            d["globs"] = self._globs
        return d


class CacheVolume:
    """Named cache volume for container mounts."""

    __slots__ = ("_name",)

    def __init__(self, name: str) -> None:
        self._name = name

    @property
    def id(self) -> str:
        return self._name

    @property
    def cache_name(self) -> str:
        return self._name

    def _to_resource(self) -> dict[str, Any]:
        return {"type": "cache", "name": self._name}


# =============================================================================
# TEMPLATE
# =============================================================================


class Template:
    """Reusable task configuration template."""

    def __init__(self, name: str) -> None:
        self._name = name
        self._container: str = ""
        self._workdir: str = ""
        self._env: dict[str, str] = {}
        self._mounts: list[dict[str, str]] = []

    @property
    def name(self) -> str:
        return self._name

    def container(self, image: str) -> Self:
        if not image:
            raise ValueError("container image cannot be empty")
        self._container = image
        return self

    def workdir(self, path: str) -> Self:
        self._workdir = path
        return self

    def env(self, key: str, val: str) -> Self:
        if not key:
            raise ValueError("env key cannot be empty")
        self._env[key] = val
        return self

    def mount(self, directory: Directory, path: str) -> Self:
        if not path or not path.startswith("/"):
            raise ValueError(f"mount path must be absolute, got: {path!r}")
        self._mounts.append({"resource": directory.id, "path": path, "type": "directory"})
        return self

    def mount_cache(self, cache: CacheVolume, path: str) -> Self:
        if not path or not path.startswith("/"):
            raise ValueError(f"mount path must be absolute, got: {path!r}")
        self._mounts.append({"resource": cache.id, "path": path, "type": "cache"})
        return self


# =============================================================================
# TASK GROUP
# =============================================================================


class TaskGroup:
    """Result of chain/parallel/matrix combinators. Holds task names for dependency resolution."""

    __slots__ = ("_name", "_task_names")

    def __init__(self, name: str, task_names: list[str]) -> None:
        self._name = name
        self._task_names = task_names

    @property
    def name(self) -> str:
        return self._name

    @property
    def task_names(self) -> list[str]:
        return list(self._task_names)

    @property
    def last_tasks(self) -> list[str]:
        """Task names at the end of the group (for after_group chaining)."""
        return list(self._task_names)


# =============================================================================
# TASK
# =============================================================================


class Task:
    """A single task in the pipeline. Created via ``Pipeline.task()`` or ``Pipeline.gate()``.

    All setter methods return ``self`` for fluent chaining.
    """

    def __init__(self, pipeline: Pipeline, name: str, *, is_gate: bool = False) -> None:
        self._pipeline = pipeline
        self._name = name
        self._is_gate = is_gate
        self._command: str = ""
        self._container: str = ""
        self._workdir: str = ""
        self._env: dict[str, str] = {}
        self._mounts: list[dict[str, str]] = []
        self._inputs: list[str] = []
        self._outputs: dict[str, str] = {}
        self._outputs_v1: list[str] = []
        self._depends_on: list[str] = []
        self._when: str = ""
        self._secrets: list[str] = []
        self._secret_refs: list[SecretRef] = []
        self._matrix: dict[str, list[str]] = {}
        self._services: list[dict[str, str]] = []
        self._retry: int = 0
        self._timeout: int = 0
        self._target: str = ""
        self._k8s: K8sOptions | None = None
        self._k8s_raw: str = ""
        self._requires: list[str] = []
        self._task_inputs: list[dict[str, str]] = []
        # AI-native
        self._covers: list[str] = []
        self._intent: str = ""
        self._criticality: str = ""
        self._on_fail: str = ""
        self._select: str = ""
        # Capability-based dependencies
        self._provides: list[dict[str, str]] = []
        self._needs: list[str] = []
        # Gate fields
        self._gate_strategy: str = "prompt" if is_gate else ""
        self._gate_timeout: int = 3600 if is_gate else 0
        self._gate_message: str = ""
        self._gate_env_var: str = ""
        self._gate_file_path: str = ""

    @property
    def name(self) -> str:
        return self._name

    # ─────────────────────────────────────────────────────────────────────────
    # CORE
    # ─────────────────────────────────────────────────────────────────────────

    def run(self, cmd: str) -> Self:
        if not cmd:
            raise ValueError(f"task {self._name!r}: command cannot be empty")
        self._command = cmd
        return self

    def after(self, *tasks: str) -> Self:
        for t in tasks:
            if t and t not in self._depends_on:
                self._depends_on.append(t)
        return self

    def after_group(self, *groups: TaskGroup) -> Self:
        for g in groups:
            for t in g.last_tasks:
                if t not in self._depends_on:
                    self._depends_on.append(t)
        return self

    def inputs(self, *patterns: str) -> Self:
        self._inputs.extend(patterns)
        return self

    def when(self, cond: str | Condition) -> Self:
        self._when = str(cond)
        return self

    # ─────────────────────────────────────────────────────────────────────────
    # CONTAINER
    # ─────────────────────────────────────────────────────────────────────────

    def container(self, image: str) -> Self:
        if not image:
            raise ValueError(f"task {self._name!r}: container image cannot be empty")
        self._container = image
        return self

    def workdir(self, path: str) -> Self:
        self._workdir = path
        return self

    def mount(self, directory: Directory, path: str) -> Self:
        if not path or not path.startswith("/"):
            raise ValueError(f"task {self._name!r}: mount path must be absolute, got: {path!r}")
        self._mounts.append({"resource": directory.id, "path": path, "type": "directory"})
        self._pipeline._register_resource(directory)
        return self

    def mount_cache(self, cache: CacheVolume, path: str) -> Self:
        if not path or not path.startswith("/"):
            raise ValueError(f"task {self._name!r}: mount path must be absolute, got: {path!r}")
        self._mounts.append({"resource": cache.id, "path": path, "type": "cache"})
        self._pipeline._register_resource(cache)
        return self

    def mount_cwd(self) -> Self:
        self._mounts.append({"resource": "src:.", "path": "/work", "type": "directory"})
        self._workdir = "/work"
        return self

    def mount_cwd_at(self, path: str) -> Self:
        if not path or not path.startswith("/"):
            raise ValueError(f"task {self._name!r}: mount path must be absolute, got: {path!r}")
        self._mounts.append({"resource": "src:.", "path": path, "type": "directory"})
        self._workdir = path
        return self

    def env(self, key: str, val: str) -> Self:
        if not key:
            raise ValueError(f"task {self._name!r}: env key cannot be empty")
        self._env[key] = val
        return self

    def service(self, image: str, name: str) -> Self:
        self._services.append({"image": image, "name": name})
        return self

    # ─────────────────────────────────────────────────────────────────────────
    # ARTIFACTS
    # ─────────────────────────────────────────────────────────────────────────

    def output(self, name: str, path: str) -> Self:
        self._outputs[name] = path
        return self

    def outputs(self, *paths: str) -> Self:
        self._outputs_v1.extend(paths)
        return self

    def input_from(self, task: str, output_name: str, dest: str) -> Self:
        self._task_inputs.append({
            "from_task": task,
            "output": output_name,
            "dest": dest,
        })
        if task not in self._depends_on:
            self._depends_on.append(task)
        return self

    # ─────────────────────────────────────────────────────────────────────────
    # SECRETS
    # ─────────────────────────────────────────────────────────────────────────

    def secret(self, name: str) -> Self:
        if not name:
            raise ValueError(f"task {self._name!r}: secret name cannot be empty")
        self._secrets.append(name)
        return self

    def secrets(self, *names: str) -> Self:
        for n in names:
            self.secret(n)
        return self

    def secret_from(self, name: str, ref: SecretRef) -> Self:
        if not name:
            raise ValueError(f"task {self._name!r}: secret name cannot be empty")
        if ref.name != name:
            raise ValueError(
                f"task {self._name!r}: secret name mismatch: argument {name!r} "
                f"does not match SecretRef.name {ref.name!r}"
            )
        self._secret_refs.append(ref)
        return self

    # ─────────────────────────────────────────────────────────────────────────
    # EXECUTION
    # ─────────────────────────────────────────────────────────────────────────

    def matrix(self, key: str, *values: str) -> Self:
        self._matrix[key] = list(values)
        return self

    def retry(self, n: int) -> Self:
        if n < 0:
            raise ValueError(f"task {self._name!r}: retry count cannot be negative, got {n}")
        self._retry = n
        return self

    def timeout(self, secs: int) -> Self:
        if secs <= 0:
            raise ValueError(f"task {self._name!r}: timeout must be positive, got {secs}")
        self._timeout = secs
        return self

    def target(self, name: str) -> Self:
        self._target = name
        return self

    def k8s(self, opts: K8sOptions) -> Self:
        self._k8s = opts
        return self

    def requires(self, *labels: str) -> Self:
        self._requires.extend(labels)
        return self

    # ─────────────────────────────────────────────────────────────────────────
    # AI-NATIVE
    # ─────────────────────────────────────────────────────────────────────────

    def covers(self, *patterns: str) -> Self:
        self._covers.extend(patterns)
        return self

    def intent(self, desc: str) -> Self:
        self._intent = desc
        return self

    def critical(self) -> Self:
        self._criticality = "high"
        return self

    def set_criticality(self, level: str) -> Self:
        _validate_enum(level, ("high", "medium", "low"), "criticality", self._name)
        self._criticality = level
        return self

    def on_fail(self, action: str) -> Self:
        _validate_enum(action, ("analyze", "retry", "skip"), "on_fail", self._name)
        self._on_fail = action
        return self

    def select_mode(self, mode: str) -> Self:
        _validate_enum(mode, ("smart", "always", "manual"), "select_mode", self._name)
        self._select = mode
        return self

    def smart(self) -> Self:
        self._select = "smart"
        return self

    # ─────────────────────────────────────────────────────────────────────────
    # CAPABILITY-BASED DEPENDENCIES
    # ─────────────────────────────────────────────────────────────────────────

    def provides(self, name: str, value: str | None = None) -> Self:
        if not name:
            raise ValueError(f"task {self._name!r}: capability name cannot be empty")
        entry: dict[str, str] = {"name": name}
        if value:
            entry["value"] = value
        self._provides.append(entry)
        return self

    def needs(self, *names: str) -> Self:
        for n in names:
            if not n:
                raise ValueError(f"task {self._name!r}: capability name cannot be empty")
        self._needs.extend(names)
        return self

    # ─────────────────────────────────────────────────────────────────────────
    # TEMPLATE
    # ─────────────────────────────────────────────────────────────────────────

    def from_template(self, tmpl: Template) -> Self:
        if tmpl._container and not self._container:
            self._container = tmpl._container
        if tmpl._workdir and not self._workdir:
            self._workdir = tmpl._workdir
        # Template env is base, task env overrides
        merged = dict(tmpl._env)
        merged.update(self._env)
        self._env = merged
        # Template mounts prepended
        self._mounts = list(tmpl._mounts) + self._mounts
        return self

    # ─────────────────────────────────────────────────────────────────────────
    # GATE
    # ─────────────────────────────────────────────────────────────────────────

    def gate_strategy(self, s: str) -> Self:
        _validate_enum(s, ("prompt", "env", "file", "webhook"), "gate_strategy", self._name)
        self._gate_strategy = s
        return self

    def gate_message(self, msg: str) -> Self:
        self._gate_message = msg
        return self

    def gate_timeout(self, secs: int) -> Self:
        if secs <= 0:
            raise ValueError(f"task {self._name!r}: gate timeout must be positive, got {secs}")
        self._gate_timeout = secs
        return self

    def gate_env_var(self, var: str) -> Self:
        self._gate_env_var = var
        return self

    def gate_file_path(self, path: str) -> Self:
        self._gate_file_path = path
        return self

    # ─────────────────────────────────────────────────────────────────────────
    # SERIALIZATION
    # ─────────────────────────────────────────────────────────────────────────

    def _to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"name": self._name}

        if self._command:
            d["command"] = self._command
        if self._container:
            d["container"] = self._container
        if self._workdir:
            d["workdir"] = self._workdir
        if self._env:
            d["env"] = dict(self._env)
        if self._mounts:
            d["mounts"] = list(self._mounts)
        if self._inputs:
            d["inputs"] = list(self._inputs)
        if self._task_inputs:
            d["task_inputs"] = list(self._task_inputs)
        if self._outputs and self._outputs_v1:
            # Merge: named outputs + auto-named v1 outputs
            merged = dict(self._outputs)
            for idx, val in enumerate(self._outputs_v1):
                key = f"output_{idx}"
                while key in merged:
                    key = f"output_{idx}_{idx}"
                merged[key] = val
            d["outputs"] = merged
        elif self._outputs:
            d["outputs"] = dict(self._outputs)
        elif self._outputs_v1:
            d["outputs"] = {f"output_{i}": v for i, v in enumerate(self._outputs_v1)}
        if self._depends_on:
            d["depends_on"] = list(self._depends_on)
        if self._when:
            d["when"] = self._when
        if self._secrets:
            d["secrets"] = list(self._secrets)
        if self._secret_refs:
            d["secret_refs"] = [
                {"name": r.name, "source": r.source, "key": r.key} for r in self._secret_refs
            ]
        if self._matrix:
            d["matrix"] = {k: list(v) for k, v in self._matrix.items()}
        if self._services:
            d["services"] = list(self._services)
        if self._retry:
            d["retry"] = self._retry
        if self._timeout:
            d["timeout"] = self._timeout
        if self._target:
            d["target"] = self._target

        # K8s
        k8s_json = self._k8s_to_dict()
        if k8s_json:
            d["k8s"] = k8s_json

        if self._requires:
            d["requires"] = list(self._requires)

        # Capability-based dependencies
        if self._provides:
            d["provides"] = list(self._provides)
        if self._needs:
            d["needs"] = list(self._needs)

        # AI-native: semantic
        semantic = self._semantic_to_dict()
        if semantic:
            d["semantic"] = semantic

        # AI-native: ai_hooks
        ai_hooks = self._ai_hooks_to_dict()
        if ai_hooks:
            d["ai_hooks"] = ai_hooks

        # Gate
        if self._is_gate:
            gate: dict[str, Any] = {"strategy": self._gate_strategy}
            if self._gate_timeout:
                gate["timeout"] = self._gate_timeout
            if self._gate_message:
                gate["message"] = self._gate_message
            if self._gate_env_var:
                gate["env_var"] = self._gate_env_var
            if self._gate_file_path:
                gate["file_path"] = self._gate_file_path
            d["gate"] = gate

        return d

    def _semantic_to_dict(self) -> dict[str, Any] | None:
        if not self._covers and not self._intent and not self._criticality:
            return None
        d: dict[str, Any] = {}
        if self._covers:
            d["covers"] = list(self._covers)
        if self._intent:
            d["intent"] = self._intent
        if self._criticality:
            d["criticality"] = self._criticality
        return d

    def _ai_hooks_to_dict(self) -> dict[str, str] | None:
        if not self._on_fail and not self._select:
            return None
        d: dict[str, str] = {}
        if self._on_fail:
            d["on_fail"] = self._on_fail
        if self._select:
            d["select"] = self._select
        return d

    def k8s_raw(self, raw: str) -> Self:
        """Set raw JSON for advanced K8s options (escape hatch)."""
        self._k8s_raw = raw
        return self

    def _k8s_to_dict(self) -> dict[str, Any] | None:
        if self._k8s is None and not self._k8s_raw:
            return None
        d: dict[str, Any] = {}
        if self._k8s:
            if self._k8s.memory:
                d["memory"] = self._k8s.memory
            if self._k8s.cpu:
                d["cpu"] = self._k8s.cpu
            if self._k8s.gpu:
                d["gpu"] = self._k8s.gpu
            if self._k8s.raw:
                d["raw"] = self._k8s.raw
        if self._k8s_raw:
            d["raw"] = self._k8s_raw
        return d or None


# =============================================================================
# PIPELINE
# =============================================================================


class Pipeline:
    """Aggregate root. Owns all tasks, resources, and templates.

    Example::

        p = Pipeline()
        p.task("lint").run("ruff check .")
        p.task("test").run("pytest").after("lint")
        p.emit()
    """

    def __init__(self, *, k8s_defaults: K8sOptions | None = None) -> None:
        self._tasks: list[Task] = []
        self._task_names: set[str] = set()
        self._dirs: list[Directory] = []
        self._caches: list[CacheVolume] = []
        self._templates: dict[str, Template] = {}
        self._registered_resources: dict[str, Directory | CacheVolume] = {}
        self._k8s_defaults = k8s_defaults

    # ─────────────────────────────────────────────────────────────────────────
    # TASK / GATE CREATION
    # ─────────────────────────────────────────────────────────────────────────

    def task(self, name: str) -> Task:
        if not name:
            raise ValueError("task name cannot be empty")
        if name in self._task_names:
            raise ValueError(f"task {name!r} already exists")
        t = Task(self, name)
        self._tasks.append(t)
        self._task_names.add(name)
        log.debug("registered task %r", name)
        return t

    def gate(self, name: str) -> Task:
        if not name:
            raise ValueError("gate name cannot be empty")
        if name in self._task_names:
            raise ValueError(f"task/gate {name!r} already exists")
        t = Task(self, name, is_gate=True)
        self._tasks.append(t)
        self._task_names.add(name)
        log.debug("registered gate %r", name)
        return t

    # ─────────────────────────────────────────────────────────────────────────
    # RESOURCES
    # ─────────────────────────────────────────────────────────────────────────

    def dir(self, path: str) -> Directory:
        if not path or not path.strip():
            raise ValueError("directory path cannot be empty")
        for d in self._dirs:
            if d.path == path:
                return d
        d = Directory(path)
        self._dirs.append(d)
        return d

    def cache(self, name: str) -> CacheVolume:
        if not name or not name.strip():
            raise ValueError("cache name cannot be empty")
        for c in self._caches:
            if c.cache_name == name:
                return c
        c = CacheVolume(name)
        self._caches.append(c)
        return c

    def _register_resource(self, resource: Directory | CacheVolume) -> None:
        rid = resource.id
        if rid not in self._registered_resources:
            self._registered_resources[rid] = resource

    # ─────────────────────────────────────────────────────────────────────────
    # TEMPLATES
    # ─────────────────────────────────────────────────────────────────────────

    def template(self, name: str) -> Template:
        if not name:
            raise ValueError("template name cannot be empty")
        if name in self._templates:
            raise ValueError(f"template {name!r} already exists")
        tmpl = Template(name)
        self._templates[name] = tmpl
        return tmpl

    # ─────────────────────────────────────────────────────────────────────────
    # COMBINATORS
    # ─────────────────────────────────────────────────────────────────────────

    def chain(self, *items: Task | TaskGroup) -> TaskGroup:
        """Chain tasks/groups sequentially — each depends on the previous."""
        names: list[str] = []
        prev_names: list[str] = []

        for item in items:
            if isinstance(item, Task):
                current = [item.name]
            else:
                current = item.task_names

            if prev_names:
                for cur in current:
                    task = self._find_task(cur)
                    if task:
                        for p in prev_names:
                            task.after(p)

            names.extend(current)
            prev_names = current

        # The last tasks in the chain are the "output" of the group
        return TaskGroup("chain", prev_names)

    def parallel(self, name: str, *tasks: Task) -> TaskGroup:
        """Group tasks to run concurrently. Returns a group for dependency chaining."""
        return TaskGroup(name, [t.name for t in tasks])

    def matrix(
        self,
        name: str,
        values: Sequence[str],
        fn: Callable[[str], Task],
    ) -> TaskGroup:
        """Create tasks from a list of values."""
        task_names: list[str] = []
        for v in values:
            t = fn(v)
            task_names.append(t.name)
        return TaskGroup(name, task_names)

    def matrix_map(
        self,
        name: str,
        values: dict[str, str],
        fn: Callable[[str, str], Task],
    ) -> TaskGroup:
        """Create tasks from a dict of key-value pairs."""
        task_names: list[str] = []
        for k, v in values.items():
            t = fn(k, v)
            task_names.append(t.name)
        return TaskGroup(name, task_names)

    # ─────────────────────────────────────────────────────────────────────────
    # PRESETS
    # ─────────────────────────────────────────────────────────────────────────

    def python(self) -> PythonPreset:
        return PythonPreset(self)

    # ─────────────────────────────────────────────────────────────────────────
    # VALIDATION
    # ─────────────────────────────────────────────────────────────────────────

    def validate(self) -> None:
        """Validate the pipeline. Raises ValidationError on problems."""
        # Check all non-gate tasks have commands
        for t in self._tasks:
            if not t._is_gate and not t._command:
                raise ValidationError(
                    code="MISSING_COMMAND",
                    message=f"task {t._name!r} has no command",
                    task=t._name,
                )

        # Check all dependencies exist
        for t in self._tasks:
            for dep in t._depends_on:
                if dep not in self._task_names:
                    suggestion = _best_match(dep, self._task_names)
                    msg = f"task {t._name!r} depends on unknown task {dep!r}"
                    if suggestion:
                        msg += f" (did you mean {suggestion!r}?)"
                    raise ValidationError(
                        code="UNKNOWN_DEPENDENCY",
                        message=msg,
                        task=t._name,
                        suggestion=suggestion,
                    )

        # Cycle detection (3-color DFS)
        _detect_cycles(self._tasks)

        # K8s validation
        for t in self._tasks:
            k8s = t._k8s
            if k8s is None and self._k8s_defaults:
                k8s = self._k8s_defaults
            if k8s:
                _validate_k8s(k8s, t._name)

    # ─────────────────────────────────────────────────────────────────────────
    # EMISSION
    # ─────────────────────────────────────────────────────────────────────────

    def to_dict(self) -> dict[str, Any]:
        """Return the pipeline as a dict (for testing). Validates first."""
        self.validate()
        return self._build_output()

    def emit_to(self, writer: IO[str]) -> None:
        """Emit JSON to a writer. Validates first."""
        self.validate()
        output = self._build_output()
        json.dump(output, writer, separators=(",", ":"))

    def emit(self) -> NoReturn:
        """Check for ``--emit`` flag, emit JSON to stdout, exit.

        This calls ``sys.exit(0)`` after emission — do not use in tests.
        Use ``to_dict()`` or ``emit_to()`` instead.
        """
        if "--emit" not in sys.argv:
            sys.exit(0)
        self.emit_to(sys.stdout)
        sys.exit(0)

    # ─────────────────────────────────────────────────────────────────────────
    # EXPLAIN
    # ─────────────────────────────────────────────────────────────────────────

    def explain(self, ctx: ExplainContext | None = None) -> None:
        """Print a human-readable pipeline explanation to stderr."""
        self.explain_to(sys.stderr, ctx)

    def explain_to(self, writer: IO[str], ctx: ExplainContext | None = None) -> None:
        """Print a human-readable pipeline explanation to a writer."""
        self.validate()
        writer.write(f"Pipeline: {len(self._tasks)} tasks\n")
        for t in self._tasks:
            status = _evaluate_condition(t._when, ctx) if t._when and ctx else ""
            prefix = "  "
            if t._is_gate:
                kind = f"gate ({t._gate_strategy})"
            else:
                kind = t._command
            deps = f" (after: {', '.join(t._depends_on)})" if t._depends_on else ""
            cond = ""
            if t._when:
                if status == "skip":
                    cond = f" [SKIP: {t._when}]"
                elif status == "run":
                    cond = f" [RUN: {t._when}]"
                else:
                    cond = f" [when: {t._when}]"
            writer.write(f"{prefix}{t._name}: {kind}{deps}{cond}\n")

    # ─────────────────────────────────────────────────────────────────────────
    # INTERNAL
    # ─────────────────────────────────────────────────────────────────────────

    def _find_task(self, name: str) -> Task | None:
        for t in self._tasks:
            if t._name == name:
                return t
        return None

    def _has_v2_features(self) -> bool:
        if self._dirs or self._caches:
            return True
        for t in self._tasks:
            if t._container or t._mounts:
                return True
        return False

    def _build_output(self) -> dict[str, Any]:
        version = "2" if self._has_v2_features() else "1"
        output: dict[str, Any] = {"version": version}

        # Resources (v2)
        if version == "2":
            resources: dict[str, Any] = {}
            for d in self._dirs:
                resources[d.id] = d._to_resource()
            for c in self._caches:
                resources[c.id] = c._to_resource()
            # Also include resources registered via mounts
            for rid, r in self._registered_resources.items():
                if rid not in resources:
                    resources[rid] = r._to_resource()
            if resources:
                output["resources"] = resources

        # Tasks
        tasks_json: list[dict[str, Any]] = []
        for t in self._tasks:
            td = t._to_dict()
            # Merge k8s defaults
            if self._k8s_defaults and "k8s" not in td:
                k8s_d = _k8s_defaults_to_dict(self._k8s_defaults)
                if k8s_d:
                    td["k8s"] = k8s_d
            tasks_json.append(td)

        output["tasks"] = tasks_json
        return output


# =============================================================================
# PYTHON PRESET
# =============================================================================


class PythonPreset:
    """Language preset for Python projects."""

    _DEFAULT_INPUTS = ("**/*.py", "pyproject.toml")

    def __init__(self, pipeline: Pipeline) -> None:
        self._pipeline = pipeline

    def test(self) -> Task:
        return (
            self._pipeline.task("test")
            .run("pytest")
            .inputs(*self._DEFAULT_INPUTS)
        )

    def lint(self) -> Task:
        return (
            self._pipeline.task("lint")
            .run("ruff check .")
            .inputs(*self._DEFAULT_INPUTS)
        )

    def typecheck(self) -> Task:
        return (
            self._pipeline.task("typecheck")
            .run("mypy .")
            .inputs(*self._DEFAULT_INPUTS)
        )

    def build(self) -> Task:
        return (
            self._pipeline.task("build")
            .run("python -m build")
            .inputs(*self._DEFAULT_INPUTS)
        )


# =============================================================================
# HELPERS
# =============================================================================


def _validate_enum(value: str, allowed: tuple[str, ...], field: str, task_name: str) -> None:
    if value not in allowed:
        raise ValueError(
            f"task {task_name!r}: invalid {field} {value!r}, "
            f"must be one of: {', '.join(allowed)}"
        )


def _k8s_defaults_to_dict(k8s: K8sOptions) -> dict[str, Any] | None:
    d: dict[str, Any] = {}
    if k8s.memory:
        d["memory"] = k8s.memory
    if k8s.cpu:
        d["cpu"] = k8s.cpu
    if k8s.gpu:
        d["gpu"] = k8s.gpu
    return d or None


def _detect_cycles(tasks: list[Task]) -> None:
    """3-color DFS cycle detection. Raises ValidationError if cycle found."""
    WHITE, GRAY, BLACK = 0, 1, 2
    color: dict[str, int] = {t._name: WHITE for t in tasks}
    adj: dict[str, list[str]] = {t._name: list(t._depends_on) for t in tasks}
    path: list[str] = []

    def visit(node: str) -> None:
        color[node] = GRAY
        path.append(node)
        for dep in adj.get(node, []):
            if dep not in color:
                continue  # unknown dep — caught by dependency validation
            if color[dep] == GRAY:
                cycle_start = path.index(dep)
                cycle = path[cycle_start:] + [dep]
                raise ValidationError(
                    code="CYCLE_DETECTED",
                    message=f"dependency cycle: {' -> '.join(cycle)}",
                )
            if color[dep] == WHITE:
                visit(dep)
        path.pop()
        color[node] = BLACK

    for t in tasks:
        if color[t._name] == WHITE:
            visit(t._name)


def _validate_k8s(k8s: K8sOptions, task_name: str) -> None:
    """Validate K8s resource format."""
    import re

    if k8s.memory:
        if not re.match(r"^\d+[EPTGMK]i?$", k8s.memory):
            raise ValidationError(
                code="INVALID_K8S",
                message=f"task {task_name!r}: invalid k8s memory format {k8s.memory!r} "
                "(expected e.g. '512Mi', '4Gi')",
                task=task_name,
            )
    if k8s.cpu:
        if not re.match(r"^(\d+m?|\d+\.\d+)$", k8s.cpu):
            raise ValidationError(
                code="INVALID_K8S",
                message=f"task {task_name!r}: invalid k8s cpu format {k8s.cpu!r} "
                "(expected e.g. '500m', '2', '1.5')",
                task=task_name,
            )


# =============================================================================
# JARO-WINKLER SIMILARITY (for "did you mean?" suggestions)
# =============================================================================


def _jaro_similarity(s1: str, s2: str) -> float:
    """Jaro similarity between two strings."""
    if s1 == s2:
        return 1.0
    len1, len2 = len(s1), len(s2)
    if len1 == 0 or len2 == 0:
        return 0.0

    match_distance = max(len1, len2) // 2 - 1
    if match_distance < 0:
        match_distance = 0

    s1_matches = [False] * len1
    s2_matches = [False] * len2
    matches = 0
    transpositions = 0

    for i in range(len1):
        start = max(0, i - match_distance)
        end = min(i + match_distance + 1, len2)
        for j in range(start, end):
            if s2_matches[j] or s1[i] != s2[j]:
                continue
            s1_matches[i] = True
            s2_matches[j] = True
            matches += 1
            break

    if matches == 0:
        return 0.0

    k = 0
    for i in range(len1):
        if not s1_matches[i]:
            continue
        while not s2_matches[k]:
            k += 1
        if s1[i] != s2[k]:
            transpositions += 1
        k += 1

    return (matches / len1 + matches / len2 + (matches - transpositions / 2) / matches) / 3


def _jaro_winkler(s1: str, s2: str) -> float:
    """Jaro-Winkler similarity (adds prefix bonus)."""
    jaro = _jaro_similarity(s1, s2)
    prefix = 0
    for i in range(min(4, len(s1), len(s2))):
        if s1[i] == s2[i]:
            prefix += 1
        else:
            break
    return jaro + prefix * 0.1 * (1 - jaro)


def _best_match(name: str, candidates: set[str], threshold: float = 0.8) -> str:
    """Find the best Jaro-Winkler match above threshold."""
    best = ""
    best_score = 0.0
    for c in candidates:
        score = _jaro_winkler(name, c)
        if score > best_score and score >= threshold:
            best_score = score
            best = c
    return best


def _evaluate_condition(expr: str, ctx: ExplainContext) -> str:
    """Simple condition evaluator for explain mode."""
    # Very basic evaluator — handles common patterns
    e = expr.strip()

    if "==" in e and "||" not in e and "&&" not in e:
        parts = e.split("==", 1)
        lhs = parts[0].strip()
        rhs = parts[1].strip().strip("'\"")
        val = _get_ctx_value(lhs, ctx)
        return "run" if val == rhs else "skip"

    if "!=" in e and "||" not in e and "&&" not in e:
        parts = e.split("!=", 1)
        lhs = parts[0].strip()
        rhs = parts[1].strip().strip("'\"")
        val = _get_ctx_value(lhs, ctx)
        return "run" if val != rhs else "skip"

    if "matches" in e and "||" not in e and "&&" not in e:
        parts = e.split("matches", 1)
        lhs = parts[0].strip()
        pattern = parts[1].strip().strip("'\"")
        val = _get_ctx_value(lhs, ctx)
        import fnmatch
        return "run" if fnmatch.fnmatch(val, pattern) else "skip"

    return ""


def _get_ctx_value(field: str, ctx: ExplainContext) -> str:
    """Get a context field value."""
    if field == "branch":
        return ctx.branch
    if field == "tag":
        return ctx.tag
    if field == "event":
        return ctx.event
    if field == "ci":
        return "true" if ctx.ci else "false"
    return ""
