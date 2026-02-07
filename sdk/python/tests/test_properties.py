"""Property-based tests using hypothesis."""

import json

import pytest

try:
    from hypothesis import given, settings
    from hypothesis import strategies as st

    HAS_HYPOTHESIS = True
except ImportError:
    HAS_HYPOTHESIS = False

from sykli import Pipeline, _jaro_winkler, _jaro_similarity

pytestmark = pytest.mark.skipif(not HAS_HYPOTHESIS, reason="hypothesis not installed")


# Strategy: generate a valid task name (alphanumeric, non-empty)
task_names = st.text(
    alphabet=st.characters(whitelist_categories=("Ll", "Nd"), whitelist_characters="-_"),
    min_size=1,
    max_size=20,
).filter(lambda s: s[0].isalpha())


@given(st.lists(task_names, min_size=1, max_size=15, unique=True))
@settings(max_examples=50)
def test_random_valid_pipelines_produce_valid_json(names):
    """Any pipeline with valid unique task names and commands produces valid JSON."""
    p = Pipeline()
    prev = None
    for name in names:
        t = p.task(name).run(f"echo {name}")
        if prev:
            t.after(prev)
        prev = name

    d = p.to_dict()
    # Must be valid JSON-serializable
    output = json.dumps(d)
    parsed = json.loads(output)
    assert parsed["version"] in ("1", "2")
    assert len(parsed["tasks"]) == len(names)


@given(st.text(min_size=0, max_size=50), st.text(min_size=0, max_size=50))
@settings(max_examples=100)
def test_jaro_winkler_symmetric(s1, s2):
    """Jaro-Winkler similarity is symmetric."""
    assert _jaro_winkler(s1, s2) == pytest.approx(_jaro_winkler(s2, s1))


@given(st.text(min_size=0, max_size=50), st.text(min_size=0, max_size=50))
@settings(max_examples=100)
def test_jaro_winkler_bounded(s1, s2):
    """Jaro-Winkler similarity is always between 0 and 1."""
    score = _jaro_winkler(s1, s2)
    assert 0.0 <= score <= 1.0


@given(st.text(min_size=1, max_size=50))
@settings(max_examples=50)
def test_jaro_winkler_identity(s):
    """Identical strings have similarity 1.0."""
    assert _jaro_winkler(s, s) == 1.0


@given(st.text(min_size=0, max_size=50), st.text(min_size=0, max_size=50))
@settings(max_examples=100)
def test_jaro_similarity_symmetric(s1, s2):
    """Jaro similarity is symmetric."""
    assert _jaro_similarity(s1, s2) == pytest.approx(_jaro_similarity(s2, s1))


@given(st.text(min_size=0, max_size=50), st.text(min_size=0, max_size=50))
@settings(max_examples=100)
def test_jaro_similarity_bounded(s1, s2):
    """Jaro similarity is always between 0 and 1."""
    score = _jaro_similarity(s1, s2)
    assert 0.0 <= score <= 1.0


@given(
    st.lists(task_names, min_size=2, max_size=8, unique=True),
    st.randoms(use_true_random=False),
)
@settings(max_examples=30)
def test_cycle_detection_no_false_negatives(names, rng):
    """Create a DAG (no cycles) — validation must pass."""
    p = Pipeline()
    # Create tasks in order, each depending only on previous tasks (guaranteed DAG)
    for i, name in enumerate(names):
        t = p.task(name).run(f"echo {name}")
        if i > 0:
            # Depend on a random earlier task
            dep_idx = rng.randint(0, i - 1)
            t.after(names[dep_idx])
    # Must not raise
    p.validate()
