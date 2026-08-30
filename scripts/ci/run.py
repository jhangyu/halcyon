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
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

from . import report


@dataclass
class RunResult:
    argv: list = field(default_factory=list)
    returncode: int = 0
    stdout: str = ""
    stderr: str = ""


# cmd.exe metacharacters, copied from build_apps.py:665 (CMD_METACHARACTERS).
CMD_METACHARACTERS = set("&|<>^%\"")


def _resolve_argv(argv):
    """Windows CreateProcess() cannot exec a .BAT/.CMD directly (flutter ships
    as flutter.bat), so a bare ``["flutter", ...]`` argv fails with OSError on a
    Windows runner — the 2026-08-31 round-1 CI regression. ``build_apps.py:668``
    already solved this by resolving with ``shutil.which`` and routing batch
    files through a command interpreter; that call site uses ``shell=True``,
    which G-1 forbids anywhere under ``scripts/ci/`` (and the WP-E policy test
    fails the build on it). The list form ``[cmd, "/c", resolved, *args]`` with
    ``shell=False`` reaches the same interpreter without enabling shell
    interpretation of this process's own command line.

    The injection concern is identical to build_apps.py's and handled the same
    way: whichever route is used, Python quotes with ``list2cmdline``, which
    implements CommandLineToArgvW quoting and NOT cmd.exe quoting, so ``%VAR%``
    passes through unquoted and a metacharacter in an unspaced token is not
    escaped. ponytail: refuse rather than escape. Upgrade path: caret-escape the
    metacharacters if a legitimate argument ever needs one.

    Returns (argv, error_message). ``error_message`` is non-None only for the
    refusal; the caller turns it into a RunResult rather than an exception.
    """
    resolved = shutil.which(argv[0]) or argv[0]
    if not resolved.lower().endswith((".bat", ".cmd")):
        return [resolved, *argv[1:]], None
    for arg in argv[1:]:
        if CMD_METACHARACTERS & set(arg):
            return argv, (
                f"refusing to pass {arg!r} to the batch file {resolved}: it contains "
                "a cmd.exe metacharacter (& | < > ^ % \")."
            )
    interpreter = shutil.which("cmd") or os.environ.get("COMSPEC") or "cmd"
    return [interpreter, "/c", resolved, *argv[1:]], None


def _echo(argv, result):
    """G-0 (2026-08-31 round-1 meta-defect): a child's output must reach the job
    log, not only ``build/ci-logs/``. Failures are echoed unconditionally; a
    green run stays quiet so the log keeps its signal."""
    if result.returncode == 0:
        return
    sys.stdout.flush()
    print(f"--- FAILED (rc={result.returncode}): {' '.join(argv)}", flush=True)
    for stream in (result.stdout, result.stderr):
        if stream:
            print(stream.rstrip("\n"), flush=True)
    print("--- end of failed command output", flush=True)


def run(argv, cwd=None, env=None):
    """``subprocess.run(argv, shell=False, capture_output=True, text=True)``.

    Never raises on a non-zero child — the caller decides what a non-zero means.
    A missing executable is reported as returncode 127 with the OSError text on
    stderr, so callers always get a RunResult and never an exception.
    """
    argv = [os.fspath(a) for a in argv]
    workdir = os.fspath(Path(cwd).resolve()) if cwd is not None else None
    exec_argv, refusal = _resolve_argv(argv)
    if refusal is not None:
        result = RunResult(argv=argv, returncode=126, stdout="", stderr=f"{refusal}\n")
        _echo(argv, result)
        return result
    try:
        completed = subprocess.run(
            exec_argv,
            shell=False,
            capture_output=True,
            text=True,
            cwd=workdir,
            env=env,
        )
    except OSError as exc:
        result = RunResult(argv=argv, returncode=127, stdout="", stderr=f"{exc}\n")
        _echo(argv, result)
        return result
    result = RunResult(
        argv=argv,
        returncode=completed.returncode,
        stdout=completed.stdout or "",
        stderr=completed.stderr or "",
    )
    _echo(argv, result)
    return result


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
