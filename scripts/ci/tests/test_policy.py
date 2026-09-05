"""Mechanical restatement of AC3/R-5/G-1/G-5 as tests (Plan §WP-E).

The 2026-08-30 lesson this file encodes: a comment stating a rule does not
stop a *future* edit from violating it — only a mechanical check run on every
change does, and the check must cover code that does not exist yet, not just
today's state. Every test here is a grep/parse over the current tree, so it
catches regressions introduced after this file was written, not just the
state observed while writing it.

stdlib only (G-11). No test may shell out to a platform-specific tool — every
check here is either a pure Python file/text scan or a hash comparison.
"""

from __future__ import annotations

import hashlib
import io
import re
import tokenize
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
CI_PY = REPO_ROOT / "scripts" / "ci.py"
CI_PKG_DIR = REPO_ROOT / "scripts" / "ci"
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"

# G-6: the pin file changes only by DELIBERATE, REVIEWED rounds. The digest
# below is the last reviewed content; any later edit (values or prose) fails
# this test rather than silently landing, so an upstream release can never
# alter what Halcyon consumes without someone updating this line too.
#
# Updated 2026-08-31 (round 6, ceyx tar.gz-only consumption): the pin moved to
# the archive-based shape (archive + sha256 + per-extracted-library digests,
# plus the release's artifacts.lock digest) against v0.1.6, then was regenerated
# against v0.1.7 -- the first tar.gz-ONLY ceyx release, which also added the
# libjxl Linux/Windows dists. The value before that froze round 5's 载体中立
# state, in which no pin change was in scope.
#
# 2026-09-03 (ROI refactor T1): refreshed to the tag v0.1.10 pin, which added
# the macos-arm64 / macos-x86_64 entries when the macOS CI leg migrated off its
# committed dylibs. The digest was recomputed from the file, never transcribed.
#
# 2026-09-05 (parallel-decode campaign release cut): refreshed to the tag
# v0.1.14 pin (via `python3 scripts/build_apps.py --ceyx-release latest`,
# reviewed and committed alongside this test update in the same commit as the
# loud unpinned-member guard and the Android CEYX_FETCH_SPECS fix -- see that
# commit's message for full provenance). Every archive/library sha256 in the
# pin changed (genuine re-derivation across all platforms); recomputed from
# the file with `shasum -a 256`, never transcribed by hand.
PIN_FILE = REPO_ROOT / "scripts" / "ceyx_release_pin.json"
PIN_FILE_SHA256_REVIEWED = (
    "3c631a35347b85deaebe429073a7bc55ba3127ff8385f044240e9769166eef1f"
)


def _code_only_lines(path):
    """Returns the file's lines with every COMMENT and STRING token's text
    blanked out (replaced with spaces, preserving line/column layout), so a
    grep-style regex only matches actual code — not a docstring/comment that
    happens to *mention* the forbidden pattern (e.g. this test file's own
    explanatory prose, or a `# noqa: shell=True` style comment)."""
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    rows = [list(line) for line in lines]
    try:
        tokens = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, SyntaxError, IndentationError):
        return lines  # fall back to raw text if the file doesn't tokenize
    for tok in tokens:
        if tok.type not in (tokenize.COMMENT, tokenize.STRING):
            continue
        (start_row, start_col), (end_row, end_col) = tok.start, tok.end
        if start_row == end_row:
            row = rows[start_row - 1]
            for col in range(start_col, min(end_col, len(row))):
                row[col] = " "
        else:
            for r in range(start_row, end_row + 1):
                row = rows[r - 1]
                col_start = start_col if r == start_row else 0
                col_end = end_col if r == end_row else len(row)
                for col in range(col_start, min(col_end, len(row))):
                    row[col] = " "
    return ["".join(row) for row in rows]


def _iter_ci_python_files():
    """scripts/ci.py plus every *.py under scripts/ci/ that is CI *implementation*
    (excludes scripts/ci/tests/ itself). G-1/G-3/G-5 govern the shipped CI logic
    a workflow actually executes; the test suite's own source legitimately
    *names* the forbidden patterns in prose/regex literals in order to detect
    them (e.g. this file's own docstrings and the "|"/">" YAML block-scalar
    markers in test_render.py/test_policy.py), so self-scanning it would be a
    permanent false positive rather than a regression signal."""
    if CI_PY.is_file():
        yield CI_PY
    if CI_PKG_DIR.is_dir():
        for path in sorted(CI_PKG_DIR.rglob("*.py")):
            try:
                rel = path.relative_to(CI_PKG_DIR)
            except ValueError:
                continue
            if rel.parts and rel.parts[0] == "tests":
                continue
            yield path


def _iter_ci_module_files():
    """Same as above but excluding scripts/ci/tests/ and targets.py — used for
    the target-branching lint, which targets.py is explicitly exempt from."""
    for path in _iter_ci_python_files():
        if path == CI_PY:
            yield path
            continue
        try:
            rel = path.relative_to(CI_PKG_DIR)
        except ValueError:
            continue
        if rel.parts and rel.parts[0] == "tests":
            continue
        if path.name == "targets.py":
            continue
        yield path


class TestNoShellTrue(unittest.TestCase):
    """G-1: no shell=True anywhere under scripts/ci/ or in scripts/ci.py. Ever."""

    def test_no_shell_true(self):
        offenders = []
        for path in _iter_ci_python_files():
            for lineno, code_line in enumerate(_code_only_lines(path), start=1):
                if "shell=True" in code_line or "shell = True" in code_line:
                    offenders.append(f"{path}:{lineno}: {code_line.strip()}")
        self.assertEqual(offenders, [], f"shell=True found (G-1 violation):\n" + "\n".join(offenders))


class TestNoTargetBranching(unittest.TestCase):
    """G-5: no file under scripts/ci/ other than targets.py may branch on
    target/platform for build/package/provision logic. Per-platform facts are
    dict entries in targets.py, nowhere else."""

    PATTERN = re.compile(r"if\s+(target|platform|sys\.platform)\s*==")

    def test_no_target_branching(self):
        offenders = []
        for path in _iter_ci_module_files():
            for lineno, code_line in enumerate(_code_only_lines(path), start=1):
                if self.PATTERN.search(code_line):
                    offenders.append(f"{path}:{lineno}: {code_line.strip()}")
        self.assertEqual(
            offenders,
            [],
            f"target/platform branching found outside targets.py (G-5 violation):\n"
            + "\n".join(offenders),
        )


class TestNoPipeGrep(unittest.TestCase):
    """G-3: no argv list literal in scripts/ci/ contains '|' or 'grep' —
    nm | grep -q inverts under pipefail (SIGPIPE -> 141 when the symbol IS
    found); capture to a str and match in Python instead."""

    STRING_LITERAL_RE = re.compile(r"""(['"])((?:\\.|(?!\1).)*)\1""")

    def test_no_pipe_grep(self):
        offenders = []
        for path in _iter_ci_python_files():
            text = path.read_text(encoding="utf-8")
            for lineno, line in enumerate(text.splitlines(), start=1):
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                for _, literal in self.STRING_LITERAL_RE.findall(line):
                    if literal == "|" or literal == "grep":
                        offenders.append(f"{path}:{lineno}: {line.strip()}")
        self.assertEqual(
            offenders,
            [],
            f"'|' or 'grep' string literal found in scripts/ci/ (G-3 violation — "
            f"likely an argv element meant for a shell pipeline):\n" + "\n".join(offenders),
        )


class TestWorkflowsSingleLineRuns(unittest.TestCase):
    """AC3: every `run:` step in both workflow files is exactly one line
    beginning `python3 scripts/ci.py` (anything else must be a `uses:` step)."""

    RUN_LINE_RE = re.compile(r"^(\s*)run:\s*(.*)$")

    def _workflow_files(self):
        files = [WORKFLOWS_DIR / "ci.yml", WORKFLOWS_DIR / "release.yml"]
        existing = [f for f in files if f.is_file()]
        if not existing:
            self.skipTest(f"no workflow files found under {WORKFLOWS_DIR} yet")
        return existing

    def test_workflows_single_line_runs(self):
        offenders = []
        for wf in self._workflow_files():
            lines = wf.read_text(encoding="utf-8").splitlines()
            for i, line in enumerate(lines):
                m = self.RUN_LINE_RE.match(line)
                if not m:
                    continue
                rest = m.group(2).strip()
                if rest == "":
                    # Could be a step's `run: |` block scalar (real violation) OR
                    # the top-level `defaults: run: / working-directory: ...`
                    # mapping (not a step command at all). Distinguish by what
                    # follows: the defaults block's next non-blank line names
                    # `working-directory:`.
                    next_line = next(
                        (nl for nl in lines[i + 1 : i + 3] if nl.strip()), ""
                    )
                    if "working-directory:" in next_line:
                        continue
                    offenders.append(f"{wf}:{i + 1}: multi-line 'run:' block (block scalar)")
                    continue
                if rest in ("|", ">"):
                    offenders.append(f"{wf}:{i + 1}: multi-line 'run:' block (block scalar)")
                    continue
                if not rest.startswith("python3 scripts/ci.py"):
                    offenders.append(f"{wf}:{i + 1}: {line.strip()}")
        self.assertEqual(
            offenders,
            [],
            "every 'run:' value must be a single line beginning "
            "'python3 scripts/ci.py' (AC3):\n" + "\n".join(offenders),
        )


class TestNoBashShellInWorkflows(unittest.TestCase):
    """R-5: no `shell: bash` anywhere in either workflow file — Windows jobs
    must not build under an MSYS/bash shell (the whole path-mangling family)."""

    def test_no_bash_shell_in_workflows(self):
        files = [WORKFLOWS_DIR / "ci.yml", WORKFLOWS_DIR / "release.yml"]
        existing = [f for f in files if f.is_file()]
        if not existing:
            self.skipTest(f"no workflow files found under {WORKFLOWS_DIR} yet")
        offenders = []
        for wf in existing:
            for lineno, line in enumerate(wf.read_text(encoding="utf-8").splitlines(), start=1):
                if re.search(r"shell:\s*bash", line):
                    offenders.append(f"{wf}:{lineno}: {line.strip()}")
        self.assertEqual(
            offenders,
            [],
            "shell: bash found in a workflow file (R-5 violation):\n" + "\n".join(offenders),
        )


class TestAutoReleaseWiring(unittest.TestCase):
    """2026-09-05 auto-release contract, restated mechanically.

    Each assertion here corresponds to a way the chain silently produces
    NOTHING rather than failing: a gate that doesn't depend on the build would
    publish red code; a gate that runs on pull_request would publish from a fork
    context; a publish step without an explicit `make_latest` leaves the Latest
    marker where it was (the 2026-09-01 incident, hand-corrected twice); a
    publish step without `tag_name` cannot know its tag on the dispatch path,
    where github.ref is refs/heads/main.
    """

    def _text(self, name):
        path = WORKFLOWS_DIR / name
        if not path.is_file():
            self.skipTest(f"{path} not present")
        return path.read_text(encoding="utf-8")

    def test_ci_has_auto_release_job_gated_on_all_other_jobs(self):
        text = self._text("ci.yml")
        self.assertIn("auto-release:", text, "ci.yml has no auto-release gate job")
        self.assertIn("needs: [verify, build]", text,
                      "the gate must depend on every other job, or a red build could publish")
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/main'", text,
                      "the gate must run only on real pushes to main")
        self.assertIn("actions: write", text,
                      "dispatching release.yml under GITHUB_TOKEN needs actions: write")
        self.assertIn("python3 scripts/ci.py auto-release", text)

    def test_release_publish_step_marks_latest_explicitly(self):
        text = self._text("release.yml")
        self.assertIn("make_latest: 'true'", text,
                      "GitHub does not move the Latest marker automatically (2026-09-01)")
        self.assertIn("tag_name: ${{ env.HALCYON_VERSION }}", text,
                      "the dispatch path has no tag in github.ref; tag_name must be explicit")
        self.assertIn("inputs.publish", text,
                      "release.yml must expose a real publish path for the gate")


class TestPinFileUntouched(unittest.TestCase):
    """G-6: scripts/ceyx_release_pin.json's SHA-256 equals the last REVIEWED
    value frozen in this test. Round 6 regenerated the pin against ceyx v0.1.6
    deliberately, so the frozen digest tracks that reviewed content."""

    def test_pin_file_untouched(self):
        if not PIN_FILE.is_file():
            self.fail(f"{PIN_FILE} is missing entirely")
        # Line endings, not just PIN_FILE_SHA256_REVIEWED, must be normalized
        # (2026-09-05): this repo has no .gitattributes forcing LF, and
        # windows-latest runners checked this file out with CRLF line
        # endings while macos-14/ubuntu-latest got LF -- same committed
        # bytes, three different `git checkout`s, two different raw-byte
        # hashes. Hashing raw bytes made this test PLATFORM-DEPENDENT, which
        # defeats its own point (a single reviewed digest for the file's
        # CONTENT). Normalizing CRLF -> LF before hashing makes the digest a
        # property of the pin's actual content again, matching every other
        # platform's checkout.
        raw = PIN_FILE.read_bytes()
        normalized = raw.replace(b"\r\n", b"\n")
        actual = hashlib.sha256(normalized).hexdigest()
        self.assertEqual(
            actual,
            PIN_FILE_SHA256_REVIEWED,
            f"{PIN_FILE} changed since the last reviewed pin update "
            f"(G-6 violation): expected sha256 {PIN_FILE_SHA256_REVIEWED}, "
            f"got {actual}",
        )


if __name__ == "__main__":
    unittest.main()
