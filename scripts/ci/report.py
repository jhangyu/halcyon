"""Artifact logs and machine-checkable summary lines.

Frozen interface: Plan_ci_rewrite.md §2.

G-4: every phase writes ``build/ci-logs/<target>-<phase>.txt`` whose LAST line is
exactly ``RC=<n>``, written by the producing process. The 2026-08-23 lesson is
why the trailer exists at all: a harness notification lies in both directions
(it reported 0 for a failing run, and "failed" for a green one whose trailing
command happened to exit 1), and ``${PIPESTATUS[0]}`` silently expanded to
nothing. The only trustworthy exit code is one the producer wrote into the
artifact itself.
"""

from __future__ import annotations

from pathlib import Path


def log_path_for(repo_root, target, phase):
    """``<repo_root>/build/ci-logs/<target>-<phase>.txt``"""
    return Path(repo_root) / "build" / "ci-logs" / f"{target}-{phase}.txt"


def write_log(path, header, body, rc):
    """Creates parents; writes header, body, then a final line exactly ``RC=<rc>``.

    There is no trailing blank line after the trailer: ``tail -n 1`` must print
    ``RC=<n>`` and nothing else.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"$ {header}"]
    if body:
        lines.append(body.rstrip("\n"))
    lines.append(f"RC={rc}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def summary(target, phases, failed):
    """Returns exactly ``CI-SUMMARY: <target> phases=<n> failed=<n>``."""
    return f"CI-SUMMARY: {target} phases={phases} failed={failed}"


def skip_line(assertion_id, reason):
    """Returns exactly ``SKIP: <id> — <reason>``.

    Spec §4.5 / the 2026-08-25 lesson: a silently skipped gate produces a green
    report indistinguishable from a full run. Every legitimate skip must print
    one of these, and the summary must state the skipped count.
    """
    return f"SKIP: {assertion_id} — {reason}"
