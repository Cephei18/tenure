"""Fails if test/vectors/*.json are stale relative to the model (regenerate with: python sim/gen_vectors.py)."""

import json
import os
import random

import gen_vectors as g


def test_vectors_match_model():
    rng = random.Random(g.SEED)
    for name, fn in [("holdings", g.gen_holdings), ("nav", g.gen_nav), ("leakage", g.gen_leakage),
                     ("alpha", g.gen_alpha), ("loss", g.gen_loss), ("budget", g.gen_budget)]:
        expected = fn(rng)
        with open(os.path.join(g.OUT, f"{name}.json")) as f:
            on_disk = json.load(f)["cases"]
        assert on_disk == expected, f"{name}.json is stale: run python sim/gen_vectors.py"
        assert len(expected) >= (12 if name == "budget" else 200)
