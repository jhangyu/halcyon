"""Process execution primitives for the unified CI scripts.

Frozen interface: Plan_ci_rewrite.md §2.

  G-1  No shell interpretation, ever: ``subprocess``'s ``shell`` parameter is
       hardcoded False below and the literal enabling it appears nowhere in this
       package, so the mechanical repo-wide check for it stays clean.
  G-2  Exit codes come only from ``CompletedProcess.returncode`` — never a shell
       pipeline, never ``${PIPESTATUS[n]}``, never a harness notification.
  G-3  No ``| grep`` in any argv: ``nm | grep -q`` inverts under ``pipefail``
       (SIGPIPE -> 141 when the symbol IS found). Capture output to ``str`` and
       match in Python instead.
  G-8  Paths are ``os.fspath(Path(...).resolve())``, never string-concatenated.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from . import report


@dataclass
class RunResult:
    argv: list = field(default_factory=list)
    returncode: int = 0
    stdout: str = ""
    stderr: str = ""


def run(argv, cwd=None, env=None):
    """``subprocess.run(argv, shell=False, capture_output=True, text=True)``.

    Never raises on a non-zero child — the caller decides what a non-zero means.
    A missing executable is reported as returncode 127 with the OSError text on
    stderr, so callers always get a RunResult and never an exception.
    """
    argv = [os.fspath(a) for a in argv]
    workdir = os.fspath(Path(cwd).resolve()) if cwd is not None else None
    try:
        completed = subprocess.run(
            argv,
            shell=False,
            capture_output=True,
            text=True,
            cwd=workdir,
            env=env,
        )
    except OSError as exc:
        return RunResult(argv=argv, returncode=127, stdout="", stderr=f"{exc}\n")
    return RunResult(
        argv=argv,
        returncode=completed.returncode,
        stdout=completed.stdout or "",
        stderr=completed.stderr or "",
    )


def run_logged(argv, log_path, cwd=None):
    """``run()`` then write the G-4 artifact: header, combined output, ``RC=<n>``
    as the final line, written by this (the producing) process."""
    result = run(argv, cwd=cwd)
    body = result.stdout
    if result.stderr:
        body = body + result.stderr
    report.write_log(
        Path(log_path),
        header=" ".join(result.argv),
        body=body,
        rc=result.returncode,
    )
    return result
