"""Auto-release gate: pubspec version -> tag existence -> release dispatch.

Contract: docs/logs/2026-09-05/auto-release-contract.md (user ruling option 1).
Every green main-push CI run publishes a GitHub Release marked Latest for the
version declared in pubspec.yaml, if and only if that version's tag does not
already exist.

Why a workflow_dispatch and not a tag push
------------------------------------------
GitHub deliberately does NOT re-trigger workflows for events created with the
default ``GITHUB_TOKEN`` ("events triggered by the GITHUB_TOKEN will not create
a new workflow run"). Pushing ``v1.0.4`` from this gate would therefore create
the tag and silently run NOTHING -- a failure mode whose only symptom is an
absent run. ``workflow_dispatch`` sent through the REST API is the documented
exception: it is a dispatch, not a repository event, and it DOES start a run
under ``GITHUB_TOKEN`` (the job needs ``permissions: actions: write``).

The tag itself is created by the release publish step (softprops
``target_commitish``), not here, so a failed release build leaves no dangling
tag pointing at an unreleased commit.

G-1/G-3 apply here as everywhere under scripts/ci/: no shell, no pipelines --
``gh`` is invoked as a list argv through ``run.run`` and its output is matched
in Python.
"""

from __future__ import annotations

import re
from pathlib import Path

from . import run

# `version: 1.0.3+1` -> ("1.0.3", "1"). The suffix is captured loosely (any
# non-space run) rather than as digits-only: a non-numeric suffix must reach
# `release_tag` and be DROPPED there, not silently fail to match this regex and
# be reported as "pubspec has no version line".
VERSION_RE = re.compile(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+(\S+))?\s*$")

RELEASE_WORKFLOW = "release.yml"


def read_pubspec_version(repo_root: Path):
    """Returns ``(version, build)`` from pubspec.yaml -- ``build`` is None when
    there is no ``+`` suffix. Raises ValueError if the file has no parseable
    ``version:`` line: a loud failure, because silently defaulting would publish
    a wrong tag."""
    pubspec = Path(repo_root, "pubspec.yaml")
    for line in pubspec.read_text(encoding="utf-8").splitlines():
        match = VERSION_RE.match(line)
        if match:
            return match.group(1), match.group(2)
    raise ValueError(f"no `version: X.Y.Z` line found in {pubspec}")


def release_tag(repo_root: Path) -> str:
    """Maps pubspec's version onto the release tag (user ruling, 2026-09-05).

    A fourth segment means "bug-fix-only release, no app-side functional
    change" -- and pubspec CANNOT express it: `dart pub get` rejects a
    4-segment version. So the fourth segment rides in pubspec's build-number
    slot and is promoted back into the tag here:

        version: 1.0.3+1  ->  v1.0.3.1     (bug-fix release #1 on top of 1.0.3)
        version: 1.0.3    ->  v1.0.3       (a plain release, as before)
        version: 1.0.3+rc ->  v1.0.3       (non-numeric suffix: not a segment)

    The last case is why the suffix is dropped rather than appended blindly:
    only a bare integer carries the bug-fix-number meaning; anything else is
    build metadata that must not leak into a tag name.
    """
    version, build = read_pubspec_version(repo_root)
    if build is not None and build.isdigit():
        return f"v{version}.{build}"
    return f"v{version}"


def tag_exists(repo: str, tag: str) -> bool:
    """True iff refs/tags/<tag> exists on the remote.

    Asks for the exact ref. `git/ref/tags/<tag>` (singular `ref`) 404s for a
    missing tag -- unlike `git/refs/tags/<tag>` (plural), which PREFIX-matches
    and would report `v1.0.3` as existing while asking about `v1.0.30`.
    """
    result = run.run(["gh", "api", f"repos/{repo}/git/ref/tags/{tag}"])
    return result.returncode == 0


def auto_release(repo_root: Path, repo: str, ref: str = "main") -> int:
    """The ci.yml gate body. Returns 0 on both the skip and the dispatch path;
    non-zero only when something genuinely broke (unreadable pubspec, failed
    dispatch call), because a release decision must never redden a green CI run
    for a reason that is not a defect."""
    version, build = read_pubspec_version(repo_root)
    tag = release_tag(repo_root)
    declared = version if build is None else f"{version}+{build}"

    if tag_exists(repo, tag):
        # Loud, greppable, and the ONLY output of the idempotent path: a second
        # green run on an unchanged version must skip visibly, not quietly.
        print(f"AUTO-RELEASE-SKIP: tag {tag} already exists on {repo} -- "
              f"nothing to publish for pubspec version {declared}")
        return 0

    print(f"AUTO-RELEASE-DISPATCH: tag {tag} absent on {repo}; "
          f"dispatching {RELEASE_WORKFLOW} (ref {ref}, publish=true)")
    result = run.run([
        "gh", "workflow", "run", RELEASE_WORKFLOW,
        "--repo", repo,
        "--ref", ref,
        "-f", f"version={tag}",
        "-f", "publish=true",
    ], cwd=repo_root)
    if result.returncode != 0:
        print(f"ERROR: dispatching {RELEASE_WORKFLOW} failed with rc="
              f"{result.returncode}")
        return result.returncode
    print(f"AUTO-RELEASE-OK: {RELEASE_WORKFLOW} dispatched for {tag}")
    return 0
