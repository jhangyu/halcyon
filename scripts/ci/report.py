"""Artifact logs and machine-checkable summary lines.

Frozen interface: Plan_ci_rewrite.md §2. G-4: every phase writes
``build/ci-logs/<target>-<phase>.txt`` whose last line is exactly ``RC=<n>``,
written by the producing process (never a harness notification).
"""

from __future__ import annotations

from pathlib import Path


def log_path_for(repo_root, target, phase):
    """repo_root / 'build' / 'ci-logs' / f'{target}-{phase}.txt'"""
    raise NotImplementedError


def write_log(path, header, body, rc):
    """Creates parents; writes header, body, then a final line exactly 'RC=<rc>'."""
    raise NotImplementedError


def summary(target, phases, failed):
    """Returns exactly f'CI-SUMMARY: {target} phases={phases} failed={failed}'"""
    raise NotImplementedError


def skip_line(assertion_id, reason):
    """Returns exactly f'SKIP: {assertion_id} — {reason}'"""
    raise NotImplementedError
