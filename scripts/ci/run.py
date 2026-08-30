"""Process execution primitives for the unified CI scripts.

Frozen interface: Plan_ci_rewrite.md §2. Global constraints G-1 (never
``shell=True``), G-2 (exit codes come only from ``CompletedProcess.returncode``)
and G-3 (no ``| grep`` in any argv -- capture output and match in Python).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass
class RunResult:
    argv: list
    returncode: int
    stdout: str
    stderr: str


def run(argv, cwd=None, env=None):
    """subprocess.run(argv, shell=False, capture_output=True, text=True).

    Never raises on a non-zero child; the caller decides. G-1/G-2/G-3.
    """
    raise NotImplementedError


def run_logged(argv, log_path, cwd=None):
    """run() then report.write_log(log_path, argv, stdout+stderr, returncode). G-4."""
    raise NotImplementedError
