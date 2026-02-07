"""Tests for Task entity — every fluent method, chaining, gate methods."""

import pytest

from sykli import (
    CacheVolume,
    Directory,
    K8sOptions,
    Pipeline,
    SecretRef,
    Template,
    from_env,
    from_file,
    from_vault,
    branch,
)


class TestTaskCore:
    def test_run(self):
        p = Pipeline()
        p.task("test").run("pytest")
        assert p.to_dict()["tasks"][0]["command"] == "pytest"

    def test_run_empty_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="cannot be empty"):
            p.task("test").run("")

    def test_after(self):
        p = Pipeline()
        p.task("lint").run("ruff check .")
        p.task("test").run("pytest").after("lint")
        assert p.to_dict()["tasks"][1]["depends_on"] == ["lint"]

    def test_after_multiple(self):
        p = Pipeline()
        p.task("a").run("a")
        p.task("b").run("b")
        p.task("c").run("c").after("a", "b")
        assert set(p.to_dict()["tasks"][2]["depends_on"]) == {"a", "b"}

    def test_after_dedup(self):
        p = Pipeline()
        p.task("a").run("a")
        p.task("b").run("b").after("a").after("a")
        assert p.to_dict()["tasks"][1]["depends_on"] == ["a"]

    def test_inputs(self):
        p = Pipeline()
        p.task("test").run("pytest").inputs("**/*.py", "pyproject.toml")
        d = p.to_dict()["tasks"][0]
        assert d["inputs"] == ["**/*.py", "pyproject.toml"]

    def test_when_string(self):
        p = Pipeline()
        p.task("deploy").run("./deploy.sh").when("branch == 'main'")
        assert p.to_dict()["tasks"][0]["when"] == "branch == 'main'"

    def test_when_condition(self):
        p = Pipeline()
        p.task("deploy").run("./deploy.sh").when(branch("main"))
        assert p.to_dict()["tasks"][0]["when"] == "branch == 'main'"

    def test_name_property(self):
        p = Pipeline()
        t = p.task("test").run("pytest")
        assert t.name == "test"

    def test_fluent_chaining(self):
        p = Pipeline()
        p.task("lint").run("ruff check .")
        t = (
            p.task("test")
            .run("pytest")
            .inputs("**/*.py")
            .after("lint")
            .timeout(300)
            .retry(2)
        )
        d = p.to_dict()["tasks"][1]
        assert d["command"] == "pytest"
        assert d["inputs"] == ["**/*.py"]
        assert d["depends_on"] == ["lint"]
        assert d["timeout"] == 300
        assert d["retry"] == 2


class TestTaskContainer:
    def test_container(self):
        p = Pipeline()
        p.task("test").container("python:3.12").run("pytest")
        assert p.to_dict()["tasks"][0]["container"] == "python:3.12"

    def test_container_empty_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="cannot be empty"):
            p.task("test").container("")

    def test_workdir(self):
        p = Pipeline()
        p.task("test").container("python:3.12").workdir("/app").run("pytest")
        assert p.to_dict()["tasks"][0]["workdir"] == "/app"

    def test_mount_directory(self):
        p = Pipeline()
        src = p.dir(".")
        p.task("test").run("pytest").mount(src, "/work")
        d = p.to_dict()
        assert d["tasks"][0]["mounts"] == [
            {"resource": "src:.", "path": "/work", "type": "directory"}
        ]

    def test_mount_cache(self):
        p = Pipeline()
        c = p.cache("pip")
        p.task("test").run("pytest").mount_cache(c, "/cache")
        d = p.to_dict()
        assert d["tasks"][0]["mounts"] == [
            {"resource": "cache:pip", "path": "/cache", "type": "cache"}
        ]

    def test_mount_path_not_absolute_raises(self):
        p = Pipeline()
        src = p.dir(".")
        with pytest.raises(ValueError, match="must be absolute"):
            p.task("test").mount(src, "relative/path")

    def test_mount_cwd(self):
        p = Pipeline()
        p.task("test").run("pytest").mount_cwd()
        d = p.to_dict()
        assert d["tasks"][0]["workdir"] == "/work"
        assert d["tasks"][0]["mounts"][0]["path"] == "/work"

    def test_mount_cwd_at(self):
        p = Pipeline()
        p.task("test").run("pytest").mount_cwd_at("/app")
        d = p.to_dict()
        assert d["tasks"][0]["workdir"] == "/app"
        assert d["tasks"][0]["mounts"][0]["path"] == "/app"

    def test_env(self):
        p = Pipeline()
        p.task("test").run("pytest").env("PYTHONPATH", "/src")
        assert p.to_dict()["tasks"][0]["env"] == {"PYTHONPATH": "/src"}

    def test_env_empty_key_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="cannot be empty"):
            p.task("test").env("", "value")

    def test_service(self):
        p = Pipeline()
        p.task("test").run("pytest").service("postgres:16", "db")
        assert p.to_dict()["tasks"][0]["services"] == [
            {"image": "postgres:16", "name": "db"}
        ]


class TestTaskArtifacts:
    def test_output(self):
        p = Pipeline()
        p.task("build").run("make").output("binary", "/out/app")
        assert p.to_dict()["tasks"][0]["outputs"] == {"binary": "/out/app"}

    def test_outputs_v1(self):
        p = Pipeline()
        p.task("build").run("make").outputs("/out/app", "/out/lib")
        assert p.to_dict()["tasks"][0]["outputs"] == ["/out/app", "/out/lib"]

    def test_input_from(self):
        p = Pipeline()
        p.task("build").run("make").output("binary", "/out/app")
        p.task("deploy").run("./deploy.sh").input_from("build", "binary", "/app")
        d = p.to_dict()["tasks"][1]
        assert d["task_inputs"] == [
            {"from_task": "build", "output": "binary", "dest": "/app"}
        ]
        assert "build" in d["depends_on"]


class TestTaskSecrets:
    def test_secret(self):
        p = Pipeline()
        p.task("deploy").run("./deploy.sh").secret("TOKEN")
        assert p.to_dict()["tasks"][0]["secrets"] == ["TOKEN"]

    def test_secret_empty_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="cannot be empty"):
            p.task("deploy").secret("")

    def test_secrets_multiple(self):
        p = Pipeline()
        p.task("deploy").run("./deploy.sh").secrets("TOKEN", "KEY")
        assert p.to_dict()["tasks"][0]["secrets"] == ["TOKEN", "KEY"]

    def test_secret_from(self):
        p = Pipeline()
        ref = from_env("db_pass", "DB_PASSWORD")
        p.task("test").run("pytest").secret_from("db_pass", ref)
        d = p.to_dict()["tasks"][0]
        assert d["secret_refs"] == [
            {"name": "db_pass", "source": "env", "key": "DB_PASSWORD"}
        ]

    def test_from_file(self):
        ref = from_file("cert", "/etc/ssl/cert.pem")
        assert ref.source == "file"

    def test_from_vault(self):
        ref = from_vault("api_key", "secret/data/api")
        assert ref.source == "vault"


class TestTaskExecution:
    def test_matrix(self):
        p = Pipeline()
        p.task("test").run("pytest").matrix("python", "3.11", "3.12", "3.13")
        assert p.to_dict()["tasks"][0]["matrix"] == {
            "python": ["3.11", "3.12", "3.13"]
        }

    def test_retry(self):
        p = Pipeline()
        p.task("test").run("pytest").retry(3)
        assert p.to_dict()["tasks"][0]["retry"] == 3

    def test_retry_negative_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="cannot be negative"):
            p.task("test").retry(-1)

    def test_timeout(self):
        p = Pipeline()
        p.task("test").run("pytest").timeout(300)
        assert p.to_dict()["tasks"][0]["timeout"] == 300

    def test_timeout_zero_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="must be positive"):
            p.task("test").timeout(0)

    def test_target(self):
        p = Pipeline()
        p.task("test").run("pytest").target("k8s")
        assert p.to_dict()["tasks"][0]["target"] == "k8s"

    def test_k8s(self):
        p = Pipeline()
        p.task("test").run("pytest").k8s(K8sOptions(memory="2Gi", cpu="1"))
        d = p.to_dict()["tasks"][0]
        assert d["k8s"] == {"memory": "2Gi", "cpu": "1"}

    def test_requires(self):
        p = Pipeline()
        p.task("test").run("pytest").requires("docker", "gpu")
        assert p.to_dict()["tasks"][0]["requires"] == ["docker", "gpu"]


class TestTaskAiNative:
    def test_covers(self):
        p = Pipeline()
        p.task("test").run("pytest").covers("src/auth/*", "src/api/*")
        assert p.to_dict()["tasks"][0]["semantic"]["covers"] == [
            "src/auth/*",
            "src/api/*",
        ]

    def test_intent(self):
        p = Pipeline()
        p.task("test").run("pytest").intent("unit tests for auth")
        assert p.to_dict()["tasks"][0]["semantic"]["intent"] == "unit tests for auth"

    def test_critical(self):
        p = Pipeline()
        p.task("test").run("pytest").critical()
        assert p.to_dict()["tasks"][0]["semantic"]["criticality"] == "high"

    def test_set_criticality(self):
        p = Pipeline()
        p.task("test").run("pytest").set_criticality("low")
        assert p.to_dict()["tasks"][0]["semantic"]["criticality"] == "low"

    def test_set_criticality_invalid_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="invalid criticality"):
            p.task("test").set_criticality("extreme")

    def test_on_fail(self):
        p = Pipeline()
        p.task("test").run("pytest").on_fail("analyze")
        assert p.to_dict()["tasks"][0]["ai_hooks"]["on_fail"] == "analyze"

    def test_on_fail_invalid_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="invalid on_fail"):
            p.task("test").on_fail("explode")

    def test_select_mode(self):
        p = Pipeline()
        p.task("test").run("pytest").select_mode("smart")
        assert p.to_dict()["tasks"][0]["ai_hooks"]["select"] == "smart"

    def test_smart(self):
        p = Pipeline()
        p.task("test").run("pytest").smart()
        assert p.to_dict()["tasks"][0]["ai_hooks"]["select"] == "smart"

    def test_semantic_omitted_when_empty(self):
        p = Pipeline()
        p.task("test").run("pytest")
        assert "semantic" not in p.to_dict()["tasks"][0]

    def test_ai_hooks_omitted_when_empty(self):
        p = Pipeline()
        p.task("test").run("pytest")
        assert "ai_hooks" not in p.to_dict()["tasks"][0]


class TestTaskCapabilities:
    def test_provides(self):
        p = Pipeline()
        p.task("build").run("make").provides("binary", "/out/app")
        assert p.to_dict()["tasks"][0]["provides"] == [
            {"name": "binary", "value": "/out/app"}
        ]

    def test_provides_without_value(self):
        p = Pipeline()
        p.task("migrate").run("./migrate.sh").provides("db-ready")
        assert p.to_dict()["tasks"][0]["provides"] == [{"name": "db-ready"}]

    def test_provides_empty_name_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="cannot be empty"):
            p.task("build").provides("")

    def test_needs(self):
        p = Pipeline()
        p.task("deploy").run("./deploy.sh").needs("binary", "db-ready")
        assert p.to_dict()["tasks"][0]["needs"] == ["binary", "db-ready"]

    def test_needs_empty_name_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="cannot be empty"):
            p.task("deploy").needs("")


class TestTaskTemplate:
    def test_from_template_container(self):
        p = Pipeline()
        tmpl = p.template("python").container("python:3.12").workdir("/app")
        p.task("test").from_template(tmpl).run("pytest")
        d = p.to_dict()["tasks"][0]
        assert d["container"] == "python:3.12"
        assert d["workdir"] == "/app"

    def test_from_template_env_merge(self):
        p = Pipeline()
        tmpl = p.template("base").env("A", "1").env("B", "2")
        p.task("test").from_template(tmpl).run("pytest").env("B", "override")
        d = p.to_dict()["tasks"][0]
        assert d["env"] == {"A": "1", "B": "override"}

    def test_from_template_task_overrides(self):
        p = Pipeline()
        tmpl = p.template("base").container("python:3.11")
        p.task("test").container("python:3.12").from_template(tmpl).run("pytest")
        d = p.to_dict()["tasks"][0]
        # Task set container first, template should not override
        assert d["container"] == "python:3.12"

    def test_from_template_mounts_prepended(self):
        p = Pipeline()
        src = p.dir(".")
        cache = p.cache("pip")
        tmpl = p.template("base").mount(src, "/src")
        p.task("test").from_template(tmpl).run("pytest").mount_cache(cache, "/cache")
        d = p.to_dict()["tasks"][0]
        assert len(d["mounts"]) == 2
        assert d["mounts"][0]["type"] == "directory"
        assert d["mounts"][1]["type"] == "cache"


class TestTaskGate:
    def test_gate_basic(self):
        p = Pipeline()
        p.gate("approval").after("test")
        p.task("test").run("pytest")
        d = p.to_dict()
        gate_task = next(t for t in d["tasks"] if t["name"] == "approval")
        assert gate_task["gate"]["strategy"] == "prompt"
        assert gate_task["gate"]["timeout"] == 3600
        assert "command" not in gate_task

    def test_gate_strategy(self):
        p = Pipeline()
        p.gate("approval").gate_strategy("env")
        d = p.to_dict()
        assert d["tasks"][0]["gate"]["strategy"] == "env"

    def test_gate_message(self):
        p = Pipeline()
        p.gate("approval").gate_message("Ready to deploy?")
        d = p.to_dict()
        assert d["tasks"][0]["gate"]["message"] == "Ready to deploy?"

    def test_gate_timeout(self):
        p = Pipeline()
        p.gate("approval").gate_timeout(600)
        d = p.to_dict()
        assert d["tasks"][0]["gate"]["timeout"] == 600

    def test_gate_env_var(self):
        p = Pipeline()
        p.gate("approval").gate_strategy("env").gate_env_var("DEPLOY_APPROVED")
        d = p.to_dict()
        assert d["tasks"][0]["gate"]["env_var"] == "DEPLOY_APPROVED"

    def test_gate_file_path(self):
        p = Pipeline()
        p.gate("approval").gate_strategy("file").gate_file_path("/tmp/approved")
        d = p.to_dict()
        assert d["tasks"][0]["gate"]["file_path"] == "/tmp/approved"

    def test_gate_invalid_strategy_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="invalid gate_strategy"):
            p.gate("approval").gate_strategy("magic")

    def test_gate_timeout_zero_raises(self):
        p = Pipeline()
        with pytest.raises(ValueError, match="must be positive"):
            p.gate("approval").gate_timeout(0)

    def test_gate_with_dependencies(self):
        p = Pipeline()
        p.task("test").run("pytest")
        p.gate("approval").after("test")
        p.task("deploy").run("./deploy.sh").after("approval")
        d = p.to_dict()
        deploy = next(t for t in d["tasks"] if t["name"] == "deploy")
        assert deploy["depends_on"] == ["approval"]
