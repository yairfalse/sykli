"""Tests for Condition value object — builders, operators, string output."""

from sykli import Condition, branch, tag, has_tag, event, in_ci, not_


class TestConditionFactories:
    def test_branch_exact(self):
        c = branch("main")
        assert str(c) == "branch == 'main'"

    def test_branch_glob(self):
        c = branch("release/*")
        assert str(c) == "branch matches 'release/*'"

    def test_tag_exact(self):
        c = tag("v1.0.0")
        assert str(c) == "tag == 'v1.0.0'"

    def test_tag_glob(self):
        c = tag("v*")
        assert str(c) == "tag matches 'v*'"

    def test_has_tag(self):
        c = has_tag()
        assert str(c) == "tag != ''"

    def test_event(self):
        c = event("push")
        assert str(c) == "event == 'push'"

    def test_in_ci(self):
        c = in_ci()
        assert str(c) == "ci == true"


class TestConditionOperators:
    def test_or_method(self):
        c = branch("main").or_(tag("v*"))
        assert str(c) == "(branch == 'main') || (tag matches 'v*')"

    def test_and_method(self):
        c = branch("main").and_(event("push"))
        assert str(c) == "(branch == 'main') && (event == 'push')"

    def test_pipe_operator(self):
        c = branch("main") | tag("v*")
        assert str(c) == "(branch == 'main') || (tag matches 'v*')"

    def test_ampersand_operator(self):
        c = branch("main") & event("push")
        assert str(c) == "(branch == 'main') && (event == 'push')"

    def test_not(self):
        c = not_(branch("main"))
        assert str(c) == "!(branch == 'main')"

    def test_complex_expression(self):
        c = (branch("main") | branch("release/*")) & event("push")
        expected = (
            "((branch == 'main') || (branch matches 'release/*')) && (event == 'push')"
        )
        assert str(c) == expected

    def test_triple_or(self):
        c = branch("main") | branch("develop") | tag("v*")
        # Left-associative: ((main || develop) || v*)
        assert "||" in str(c)
        assert "main" in str(c)
        assert "develop" in str(c)
        assert "v*" in str(c)


class TestConditionEquality:
    def test_equal(self):
        assert branch("main") == branch("main")

    def test_not_equal(self):
        assert branch("main") != branch("develop")

    def test_not_equal_to_string(self):
        assert branch("main") != "branch == 'main'"

    def test_hash(self):
        s = {branch("main"), branch("main"), branch("develop")}
        assert len(s) == 2


class TestConditionRepr:
    def test_repr(self):
        c = branch("main")
        assert repr(c) == "Condition(\"branch == 'main'\")"
