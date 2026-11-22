"""M4.3: the charts regenerate from the committed CSVs (smoke test; visual review is manual)."""

import os

import pytest

plot_results = pytest.importorskip("plot_results")


def test_charts_render_from_csvs(tmp_path):
    assert plot_results.main(["plot_results.py", str(tmp_path)]) == 0
    for name in ("headline.png", "sweep.png", "slow_bleed.png"):
        path = tmp_path / name
        assert path.exists(), name
        with open(path, "rb") as f:
            assert f.read(8) == b"\x89PNG\r\n\x1a\n", name
        assert os.path.getsize(path) > 20_000, name  # a real figure, not an empty canvas


def test_headline_tier_marks_come_from_the_csv():
    rows = plot_results._read("headline.csv")
    restricted = plot_results._first(rows, "tierC", 1)
    frozen = plot_results._first(rows, "tierC", 2)
    assert restricted is not None and frozen is not None
    assert plot_results.POISON_BLOCK < restricted <= frozen
    # The honest run never leaves FULL (M4.2 acceptance), so it has no tier marks.
    assert plot_results._first(rows, "tierA", 1) is None
