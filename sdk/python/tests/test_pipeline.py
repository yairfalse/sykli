"""Tests for Pipeline aggregate root — construction, task registration, resources."""

import pytest

from sykli import (
    CacheVolume,
    Directory,
    K8sOptions,
    Pipeline,
    PythonPreset,
    Task,
    Template,
)


class TestPipelineConstruction:
    def test_empty_pipeline(self):
        p = Pipeline()
        assert p.to_dict() == {"version": "1", "tasks": []}

    def test_with_k8s_defaults(self):
        p = Pipeline(k8s_defaults=K8sOptions(memory="512Mi", cpu="1"))
        p.task("test").run("pytest")
        d = p.to_dict()
        assert d["tasks"][0]["k8s"] == {"memory": "512Mi", "cpu": "1"}

    def test_k8s_defaults_not_applied_when_task_has_own(self):
        p = Pipeline(k8s_defaults=K8sOptions(memory="512Mi"))
        p.task("test").run("pytest").k8s(K8sOptions(memory="2Gi"))
        d = p.to_dict()
        assert d["tasks"][0]["k8s"]["memory"] == "2Gi"


class TestTaskRegistration:
    def test_register_task(self):
        p = Pipeline()
        t = p.task("test")
        assert isinstance(t, Task)
        assert t.name == "test"

    def test_duplicate_task_raises(self):
        p = Pipeline()
        p.task("test")
        with pytest.raises(ValueError, match="already exists"):
            p.task("test")

    def test_empty_name_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="cannot be empty"):
            p.task("")

    def test_gate_registration(self):
        p = Pipeline()
        g = p.gate("approval")
        assert g.name == "approval"

    def test_gate_duplicate_with_task_raises(self):
        p = Pipeline()
        p.task("deploy")
        with pytest.raises(ValueError, match="already exists"):
            p.gate("deploy")

    def test_task_duplicate_with_gate_raises(self):
        p = Pipeline()
        p.gate("deploy")
        with pytest.raises(ValueError, match="already exists"):
            p.task("deploy")


class TestResourceCreation:
    def test_dir_returns_directory(self):
        p = Pipeline()
        d = p.dir("src")
        assert isinstance(d, Directory)
        assert d.id == "src:src"

    def test_dir_deduplication(self):
        p = Pipeline()
        d1 = p.dir("src")
        d2 = p.dir("src")
        assert d1 is d2

    def test_cache_returns_cache_volume(self):
        p = Pipeline()
        c = p.cache("pip")
        assert isinstance(c, CacheVolume)
        assert c.id == "pip"

    def test_cache_deduplication(self):
        p = Pipeline()
        c1 = p.cache("pip")
        c2 = p.cache("pip")
        assert c1 is c2


class TestTemplateCreation:
    def test_create_template(self):
        p = Pipeline()
        tmpl = p.template("python")
        assert isinstance(tmpl, Template)
        assert tmpl.name == "python"

    def test_duplicate_template_raises(self):
        p = Pipeline()
        p.template("python")
        with pytest.raises(ValueError, match="already exists"):
            p.template("python")


class TestVersionDetection:
    def test_v1_without_containers(self):
        p = Pipeline()
        p.task("test").run("pytest")
        assert p.to_dict()["version"] == "1"

    def test_v2_with_container(self):
        p = Pipeline()
        p.task("test").container("python:3.12").run("pytest")
        assert p.to_dict()["version"] == "2"

    def test_v2_with_directory(self):
        p = Pipeline()
        src = p.dir(".")
        p.task("test").run("pytest").mount(src, "/work")
        assert p.to_dict()["version"] == "2"

    def test_v2_with_cache(self):
        p = Pipeline()
        c = p.cache("pip")
        p.task("test").run("pytest").mount_cache(c, "/cache")
        assert p.to_dict()["version"] == "2"


class TestPythonPreset:
    def test_preset_returns_preset(self):
        p = Pipeline()
        preset = p.python()
        assert isinstance(preset, PythonPreset)

    def test_preset_test(self):
        p = Pipeline()
        p.python().test()
        d = p.to_dict()
        assert d["tasks"][0]["name"] == "test"
        assert d["tasks"][0]["command"] == "pytest"
        assert "**/*.py" in d["tasks"][0]["inputs"]

    def test_preset_lint(self):
        p = Pipeline()
        p.python().lint()
        d = p.to_dict()
        assert d["tasks"][0]["command"] == "ruff check ."

    def test_preset_typecheck(self):
        p = Pipeline()
        p.python().typecheck()
        d = p.to_dict()
        assert d["tasks"][0]["command"] == "mypy ."

    def test_preset_build(self):
        p = Pipeline()
        p.python().build()
        d = p.to_dict()
        assert d["tasks"][0]["command"] == "python -m build"

    def test_preset_tasks_chain(self):
        p = Pipeline()
        p.python().lint()
        p.python().test().after("lint")
        p.python().build().after("test")
        d = p.to_dict()
        assert len(d["tasks"]) == 3
        assert d["tasks"][2]["depends_on"] == ["test"]


class TestEmit:
    def test_emit_to_writer(self):
        import io

        p = Pipeline()
        p.task("test").run("pytest")
        writer = io.StringIO()
        p.emit_to(writer)
        output = writer.getvalue()
        parsed = json.loads(output)
        assert parsed["version"] == "1"
        assert parsed["tasks"][0]["name"] == "test"

    def test_to_dict(self):
        p = Pipeline()
        p.task("test").run("pytest")
        d = p.to_dict()
        assert isinstance(d, dict)
        assert "tasks" in d


class TestExplain:
    def test_explain_to_writer(self):
        import io

        from sykli import ExplainContext

        p = Pipeline()
        p.task("lint").run("ruff check .")
        p.task("test").run("pytest").after("lint")

        writer = io.StringIO()
        p.explain_to(writer)
        output = writer.getvalue()
        assert "lint" in output
        assert "test" in output
        assert "2 tasks" in output

    def test_explain_with_context(self):
        import io

        from sykli import ExplainContext, branch

        p = Pipeline()
        p.task("deploy").run("./deploy.sh").when(branch("main"))

        ctx = ExplainContext(branch="main")
        writer = io.StringIO()
        p.explain_to(writer, ctx)
        output = writer.getvalue()
        assert "RUN" in output

    def test_explain_skip_condition(self):
        import io

        from sykli import ExplainContext, branch

        p = Pipeline()
        p.task("deploy").run("./deploy.sh").when(branch("main"))

        ctx = ExplainContext(branch="develop")
        writer = io.StringIO()
        p.explain_to(writer, ctx)
        output = writer.getvalue()
        assert "SKIP" in output


import json
