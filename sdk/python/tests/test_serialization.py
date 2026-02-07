"""Tests for JSON serialization — wire format, omitempty, version detection."""

import io
import json

from sykli import K8sOptions, Pipeline, from_env, branch


class TestJsonWireFormat:
    def test_minimal_task(self):
        p = Pipeline()
        p.task("test").run("pytest")
        d = p.to_dict()
        task = d["tasks"][0]
        assert task == {"name": "test", "command": "pytest"}

    def test_full_task(self):
        p = Pipeline()
        (
            p.task("test")
            .run("pytest")
            .container("python:3.12")
            .workdir("/app")
            .env("CI", "true")
            .inputs("**/*.py")
            .after("lint")
            .when(branch("main"))
            .secret("TOKEN")
            .secret_from("db", from_env("db", "DB_PASS"))
            .retry(2)
            .timeout(300)
            .target("k8s")
            .k8s(K8sOptions(memory="4Gi", cpu="2"))
            .requires("docker")
            .provides("test-result", "/out/report.xml")
            .needs("db-ready")
            .covers("src/*")
            .intent("unit tests")
            .set_criticality("high")
            .on_fail("analyze")
            .select_mode("smart")
        )
        # Add the lint dep so validation passes
        p.task("lint").run("ruff check .")
        d = p.to_dict()
        task = d["tasks"][0]

        assert task["name"] == "test"
        assert task["command"] == "pytest"
        assert task["container"] == "python:3.12"
        assert task["workdir"] == "/app"
        assert task["env"] == {"CI": "true"}
        assert task["inputs"] == ["**/*.py"]
        assert task["depends_on"] == ["lint"]
        assert task["when"] == "branch == 'main'"
        assert task["secrets"] == ["TOKEN"]
        assert task["secret_refs"] == [{"name": "db", "source": "env", "key": "DB_PASS"}]
        assert task["retry"] == 2
        assert task["timeout"] == 300
        assert task["target"] == "k8s"
        assert task["k8s"] == {"memory": "4Gi", "cpu": "2"}
        assert task["requires"] == ["docker"]
        assert task["provides"] == [{"name": "test-result", "value": "/out/report.xml"}]
        assert task["needs"] == ["db-ready"]
        assert task["semantic"] == {
            "covers": ["src/*"],
            "intent": "unit tests",
            "criticality": "high",
        }
        assert task["ai_hooks"] == {"on_fail": "analyze", "select": "smart"}


class TestOmitempty:
    """All optional fields should be omitted when empty/zero/unset."""

    def test_empty_fields_omitted(self):
        p = Pipeline()
        p.task("test").run("pytest")
        task = p.to_dict()["tasks"][0]

        omitted = [
            "container", "workdir", "env", "mounts", "inputs",
            "task_inputs", "outputs", "depends_on", "when",
            "secrets", "secret_refs", "matrix", "services",
            "retry", "timeout", "target", "k8s", "requires",
            "provides", "needs", "semantic", "ai_hooks", "gate",
        ]
        for field in omitted:
            assert field not in task, f"field {field!r} should be omitted"

    def test_gate_fields_omitted_on_regular_task(self):
        p = Pipeline()
        p.task("test").run("pytest")
        assert "gate" not in p.to_dict()["tasks"][0]


class TestJsonOutput:
    def test_compact_json(self):
        p = Pipeline()
        p.task("test").run("pytest")
        writer = io.StringIO()
        p.emit_to(writer)
        output = writer.getvalue()
        # Compact JSON — no spaces after : or ,
        assert ": " not in output
        assert ", " not in output

    def test_valid_json(self):
        p = Pipeline()
        p.task("a").run("a")
        p.task("b").run("b").after("a")
        writer = io.StringIO()
        p.emit_to(writer)
        parsed = json.loads(writer.getvalue())
        assert parsed["version"] == "1"
        assert len(parsed["tasks"]) == 2


class TestResourceSerialization:
    def test_directory_in_resources(self):
        p = Pipeline()
        src = p.dir("src")
        p.task("test").run("pytest").mount(src, "/src")
        d = p.to_dict()
        assert "src:src" in d["resources"]
        assert d["resources"]["src:src"] == {"type": "directory", "path": "src"}

    def test_cache_in_resources(self):
        p = Pipeline()
        c = p.cache("pip")
        p.task("test").run("pytest").mount_cache(c, "/cache")
        d = p.to_dict()
        assert "pip" in d["resources"]
        assert d["resources"]["pip"] == {"type": "cache", "name": "pip"}

    def test_directory_with_globs(self):
        p = Pipeline()
        src = p.dir("src").glob("**/*.py", "*.toml")
        p.task("test").run("pytest").mount(src, "/src")
        d = p.to_dict()
        assert d["resources"]["src:src"]["glob"] == ["**/*.py", "*.toml"]


class TestGateSerialization:
    def test_gate_json_format(self):
        p = Pipeline()
        (
            p.gate("approval")
            .gate_strategy("env")
            .gate_timeout(600)
            .gate_message("Ready?")
            .gate_env_var("APPROVED")
        )
        d = p.to_dict()
        gate = d["tasks"][0]["gate"]
        assert gate == {
            "strategy": "env",
            "timeout": 600,
            "message": "Ready?",
            "env_var": "APPROVED",
        }

    def test_gate_omits_empty_fields(self):
        p = Pipeline()
        p.gate("approval")
        gate = p.to_dict()["tasks"][0]["gate"]
        assert "message" not in gate
        assert "env_var" not in gate
        assert "file_path" not in gate
