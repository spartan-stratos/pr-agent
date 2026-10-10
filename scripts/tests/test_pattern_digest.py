"""Tests for scripts/pattern-digest.py.

The defect these pin: a head cut kept a pattern's mechanism prose and dropped `## DO flag` /
`## Do NOT flag` / `## How to recognize in a diff`, which is the half that changes a review.
"""
import importlib.util
import pathlib

import pytest

_SRC = pathlib.Path(__file__).resolve().parents[1] / "pattern-digest.py"
_spec = importlib.util.spec_from_file_location("pattern_digest", _SRC)
pd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pd)


def _pattern(*, rules_len=2000, flag_len=400):
    return "\n".join([
        "triggers: db.replica db.primary",
        "repos: service-alpha",
        "",
        "# Reads must pick the right pool",
        "",
        "Lead paragraph explaining the mechanism.",
        "",
        "## Rules",
        "r" * rules_len,
        "",
        "## Do NOT flag",
        "n" * flag_len,
        "",
        "## DO flag",
        "d" * flag_len,
        "",
        "## How to recognize in a diff",
        "h" * flag_len,
        "",
        "## Evidence",
        "e" * 800,
    ])


def test_metadata_lines_are_stripped():
    out = pd.digest(_pattern(), 3000)
    assert "triggers:" not in out
    assert "repos:" not in out


def test_rule_statement_always_survives():
    assert "# Reads must pick the right pool" in pd.digest(_pattern(), 1200)


def test_actionable_sections_beat_a_long_rules_section():
    """The real failure: `## Rules` sits first in the file and is long enough to eat the budget."""
    out = pd.digest(_pattern(rules_len=5000), 3000)
    for heading in ("## Do NOT flag", "## DO flag", "## How to recognize in a diff"):
        assert heading in out, f"{heading} was starved by the long Rules section"


def test_provenance_is_sacrificed_before_instructions():
    out = pd.digest(_pattern(rules_len=4000), 3000)
    assert "## Evidence" not in out
    assert "## DO flag" in out


def test_never_exceeds_the_cap():
    for cap in (600, 1000, 2000, 3000, 6000):
        assert len(pd.digest(_pattern(rules_len=4000), cap)) <= cap, cap


def test_small_file_passes_through_whole():
    body = "triggers: foo\n\n# Title\n\nBody text.\n\n## DO flag\n\nSomething.\n"
    out = pd.digest(body, 3000)
    assert "## DO flag" in out and "Body text." in out and "triggers:" not in out


def test_file_with_no_sections_still_yields_the_title():
    out = pd.digest("triggers: foo\n\n# Only a title\n\n" + "x" * 5000, 1000)
    assert out.startswith("# Only a title")
    assert len(out) <= 1000


def test_omitted_sections_are_announced():
    assert "omitted for length" in pd.digest(_pattern(rules_len=6000), 1500)


@pytest.mark.parametrize("heading,expected_tier", [
    ("## Do NOT flag", 0),
    ("## Don't flag", 0),
    ("## DO flag", 0),
    ("## How to recognize in a diff", 0),
    ("## How to recognise it in a diff", 0),
    ("## Before approving", 0),
    ("## Rules", 0),
    ("## The mechanism", 1),
    ("## Evidence", 2),
    ("## Companion patterns", 2),
])
def test_heading_tiers(heading, expected_tier):
    assert pd.rank(heading)[0] == expected_tier


def test_cut_breaks_on_a_line_boundary():
    text = "line one here\nline two here\nline three here"
    out = pd._cut(text, 30)
    assert out.endswith("...")
    assert "line two here" not in out.replace("...", "") or out.count("\n") >= 1
