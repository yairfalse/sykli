"""Tests for validation — fail-fast, deferred, cycles, Jaro-Winkler suggestions."""

import pytest

from sykli import K8sOptions, Pipeline, ValidationError
from sykli import _jaro_similarity, _jaro_winkler, _best_match


class TestFailFastValidation:
    """Errors raised immediately at call time (ValueError)."""

    def test_empty_task_name(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("")

    def test_duplicate_task_name(self):
        p = Pipeline()
        p.task("test")
        with pytest.raises(ValueError):
            p.task("test")

    def test_empty_command(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("test").run("")

    def test_empty_env_key(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("test").env("", "value")

    def test_empty_secret_name(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("test").secret("")

    def test_negative_retry(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("test").retry(-1)

    def test_non_positive_timeout(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("test").timeout(0)

    def test_relative_mount_path(self):
        p = Pipeline()
        src = p.dir(".")
        with pytest.raises(ValueError, match="must be absolute"):
            p.task("test").mount(src, "relative")

    def test_empty_container_image(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("test").container("")

    def test_invalid_criticality(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("test").set_criticality("extreme")

    def test_invalid_on_fail(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("test").on_fail("explode")

    def test_invalid_select_mode(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("test").select_mode("random")

    def test_invalid_gate_strategy(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.gate("x").gate_strategy("magic")

    def test_empty_capability_name(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("test").provides("")

    def test_empty_needs_name(self):
        p = Pipeline()
        with pytest.raises(ValueError):
            p.task("test").needs("")


class TestDeferredValidation:
    """Errors raised at emit/validate time (ValidationError)."""

    def test_missing_command(self):
        p = Pipeline()
        p.task("test")
        with pytest.raises(ValidationError) as exc_info:
            p.validate()
        assert exc_info.value.code == "MISSING_COMMAND"
        assert exc_info.value.task == "test"

    def test_gate_no_command_ok(self):
        p = Pipeline()
        p.gate("approval")
        # Should not raise — gates don't need commands
        p.validate()

    def test_unknown_dependency(self):
        p = Pipeline()
        p.task("test").run("pytest").after("lint")
        with pytest.raises(ValidationError) as exc_info:
            p.validate()
        assert exc_info.value.code == "UNKNOWN_DEPENDENCY"
        assert exc_info.value.task == "test"

    def test_unknown_dependency_with_suggestion(self):
        p = Pipeline()
        p.task("lint").run("ruff check .")
        p.task("test").run("pytest").after("lintt")  # typo
        with pytest.raises(ValidationError) as exc_info:
            p.validate()
        assert exc_info.value.code == "UNKNOWN_DEPENDENCY"
        assert exc_info.value.suggestion == "lint"
        assert "did you mean" in str(exc_info.value)


class TestCycleDetection:
    def test_simple_cycle(self):
        p = Pipeline()
        p.task("a").run("a").after("b")
        p.task("b").run("b").after("a")
        with pytest.raises(ValidationError) as exc_info:
            p.validate()
        assert exc_info.value.code == "CYCLE_DETECTED"

    def test_transitive_cycle(self):
        p = Pipeline()
        p.task("a").run("a").after("c")
        p.task("b").run("b").after("a")
        p.task("c").run("c").after("b")
        with pytest.raises(ValidationError) as exc_info:
            p.validate()
        assert exc_info.value.code == "CYCLE_DETECTED"

    def test_self_cycle(self):
        p = Pipeline()
        p.task("a").run("a").after("a")
        with pytest.raises(ValidationError) as exc_info:
            p.validate()
        assert exc_info.value.code == "CYCLE_DETECTED"

    def test_no_cycle(self):
        p = Pipeline()
        p.task("a").run("a")
        p.task("b").run("b").after("a")
        p.task("c").run("c").after("a", "b")
        # Should not raise
        p.validate()

    def test_diamond_no_cycle(self):
        p = Pipeline()
        p.task("a").run("a")
        p.task("b").run("b").after("a")
        p.task("c").run("c").after("a")
        p.task("d").run("d").after("b", "c")
        p.validate()


class TestK8sValidation:
    def test_valid_memory(self):
        p = Pipeline()
        p.task("test").run("pytest").k8s(K8sOptions(memory="512Mi"))
        p.validate()

    def test_invalid_memory(self):
        p = Pipeline()
        p.task("test").run("pytest").k8s(K8sOptions(memory="512mb"))
        with pytest.raises(ValidationError) as exc_info:
            p.validate()
        assert exc_info.value.code == "INVALID_K8S"

    def test_valid_cpu(self):
        p = Pipeline()
        p.task("test").run("pytest").k8s(K8sOptions(cpu="500m"))
        p.validate()

    def test_valid_cpu_decimal(self):
        p = Pipeline()
        p.task("test").run("pytest").k8s(K8sOptions(cpu="1.5"))
        p.validate()

    def test_invalid_cpu(self):
        p = Pipeline()
        p.task("test").run("pytest").k8s(K8sOptions(cpu="two"))
        with pytest.raises(ValidationError) as exc_info:
            p.validate()
        assert exc_info.value.code == "INVALID_K8S"


class TestJaroWinkler:
    def test_identical_strings(self):
        assert _jaro_similarity("test", "test") == 1.0
        assert _jaro_winkler("test", "test") == 1.0

    def test_empty_strings(self):
        assert _jaro_similarity("", "test") == 0.0
        assert _jaro_similarity("test", "") == 0.0
        assert _jaro_similarity("", "") == 1.0

    def test_symmetric(self):
        assert _jaro_similarity("abc", "bca") == _jaro_similarity("bca", "abc")
        assert _jaro_winkler("abc", "bca") == _jaro_winkler("bca", "abc")

    def test_bounded(self):
        score = _jaro_winkler("lint", "lintt")
        assert 0.0 <= score <= 1.0

    def test_similar_strings_high_score(self):
        score = _jaro_winkler("lint", "lintt")
        assert score > 0.8

    def test_dissimilar_strings_low_score(self):
        score = _jaro_winkler("abc", "xyz")
        assert score < 0.5

    def test_prefix_bonus(self):
        jaro = _jaro_similarity("test", "testing")
        jw = _jaro_winkler("test", "testing")
        assert jw >= jaro  # Winkler adds prefix bonus

    def test_best_match_found(self):
        candidates = {"lint", "test", "build", "deploy"}
        assert _best_match("lintt", candidates) == "lint"
        assert _best_match("testt", candidates) == "test"

    def test_best_match_no_match(self):
        candidates = {"lint", "test", "build"}
        assert _best_match("zzzzz", candidates) == ""

    def test_best_match_empty_candidates(self):
        assert _best_match("test", set()) == ""


class TestValidateMethod:
    def test_validate_called_by_to_dict(self):
        p = Pipeline()
        p.task("test")  # no command
        with pytest.raises(ValidationError):
            p.to_dict()

    def test_validate_called_by_emit_to(self):
        import io

        p = Pipeline()
        p.task("test")  # no command
        with pytest.raises(ValidationError):
            p.emit_to(io.StringIO())
