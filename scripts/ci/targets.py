"""Per-target CI data. DATA ONLY.

Frozen interface: Plan_ci_rewrite.md §2. G-5: this is the ONLY file under
``scripts/ci/`` allowed to state a per-platform fact. No ``import subprocess``,
no platform branching anywhere else.
"""

from __future__ import annotations

TARGETS: dict = {}


def target_names():
    """Sorted list of valid target names."""
    raise NotImplementedError


def spec(target):
    """Returns TARGETS[target]; raises KeyError naming the valid targets."""
    raise NotImplementedError
