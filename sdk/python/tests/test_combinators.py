"""Tests for pipeline combinators — chain, parallel, matrix, matrix_map."""

from sykli import Pipeline, TaskGroup


class TestChain:
    def test_chain_two_tasks(self):
        p = Pipeline()
        a = p.task("a").run("a")
        b = p.task("b").run("b")
        g = p.chain(a, b)
        d = p.to_dict()
        task_b = next(t for t in d["tasks"] if t["name"] == "b")
        assert task_b["depends_on"] == ["a"]

    def test_chain_three_tasks(self):
        p = Pipeline()
        a = p.task("a").run("a")
        b = p.task("b").run("b")
        c = p.task("c").run("c")
        p.chain(a, b, c)
        d = p.to_dict()
        assert next(t for t in d["tasks"] if t["name"] == "b")["depends_on"] == ["a"]
        assert next(t for t in d["tasks"] if t["name"] == "c")["depends_on"] == ["b"]

    def test_chain_returns_task_group(self):
        p = Pipeline()
        a = p.task("a").run("a")
        b = p.task("b").run("b")
        g = p.chain(a, b)
        assert isinstance(g, TaskGroup)
        assert g.last_tasks == ["b"]

    def test_chain_with_groups(self):
        p = Pipeline()
        a = p.task("a").run("a")
        b = p.task("b").run("b")
        c = p.task("c").run("c")
        g1 = p.parallel("ab", a, b)
        p.chain(g1, c)
        d = p.to_dict()
        task_c = next(t for t in d["tasks"] if t["name"] == "c")
        assert set(task_c["depends_on"]) == {"a", "b"}


class TestParallel:
    def test_parallel_returns_group(self):
        p = Pipeline()
        a = p.task("a").run("a")
        b = p.task("b").run("b")
        g = p.parallel("ab", a, b)
        assert isinstance(g, TaskGroup)
        assert g.name == "ab"
        assert set(g.task_names) == {"a", "b"}

    def test_parallel_no_deps_added(self):
        p = Pipeline()
        a = p.task("a").run("a")
        b = p.task("b").run("b")
        p.parallel("ab", a, b)
        d = p.to_dict()
        assert "depends_on" not in d["tasks"][0]
        assert "depends_on" not in d["tasks"][1]


class TestAfterGroup:
    def test_after_group(self):
        p = Pipeline()
        a = p.task("a").run("a")
        b = p.task("b").run("b")
        g = p.parallel("ab", a, b)
        p.task("c").run("c").after_group(g)
        d = p.to_dict()
        task_c = next(t for t in d["tasks"] if t["name"] == "c")
        assert set(task_c["depends_on"]) == {"a", "b"}


class TestMatrix:
    def test_matrix(self):
        p = Pipeline()
        g = p.matrix(
            "test",
            ["3.11", "3.12", "3.13"],
            lambda v: p.task(f"test-{v}").run(f"python{v} -m pytest"),
        )
        assert isinstance(g, TaskGroup)
        assert len(g.task_names) == 3
        d = p.to_dict()
        assert len(d["tasks"]) == 3

    def test_matrix_map(self):
        p = Pipeline()
        envs = {"staging": "stg.example.com", "production": "prod.example.com"}
        g = p.matrix_map(
            "deploy",
            envs,
            lambda k, v: p.task(f"deploy-{k}").run(f"./deploy.sh {v}"),
        )
        assert isinstance(g, TaskGroup)
        assert len(g.task_names) == 2


class TestCombinatorComposition:
    """Test combining chain + parallel + matrix together."""

    def test_chain_parallel_chain(self):
        p = Pipeline()
        lint = p.task("lint").run("ruff check .")

        test_a = p.task("test-a").run("pytest tests/a")
        test_b = p.task("test-b").run("pytest tests/b")
        tests = p.parallel("tests", test_a, test_b)

        deploy = p.task("deploy").run("./deploy.sh")

        p.chain(lint, tests, deploy)

        d = p.to_dict()
        # lint has no deps
        assert "depends_on" not in next(t for t in d["tasks"] if t["name"] == "lint")
        # test-a and test-b depend on lint
        assert next(t for t in d["tasks"] if t["name"] == "test-a")["depends_on"] == ["lint"]
        assert next(t for t in d["tasks"] if t["name"] == "test-b")["depends_on"] == ["lint"]
        # deploy depends on both tests
        deploy_task = next(t for t in d["tasks"] if t["name"] == "deploy")
        assert set(deploy_task["depends_on"]) == {"test-a", "test-b"}
