"""Auto-release gate behaviour (2026-09-05 contract).

The two paths that matter are the ones nobody can afford to observe only in
production: the SKIP path (a second green run on an unchanged version must not
create a duplicate release) and the DISPATCH path (the exact API call that is
allowed to start a workflow under GITHUB_TOKEN). Both are asserted here against
a recorded fake of ``run.run`` — no network, no ``gh``, so they run identically
on a laptop and on all three CI runners.
"""

from __future__ import annotations

import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import ci.release_gate as release_gate  # noqa: E402
import ci.run as run_module  # noqa: E402


class FakeRun:
    """Records every argv and replies from a queue of return codes."""

    def __init__(self, codes):
        self.codes = list(codes)
        self.calls = []

    def __call__(self, argv, cwd=None, env=None):
        self.calls.append(list(argv))
        code = self.codes.pop(0) if self.codes else 0
        return run_module.RunResult(argv=list(argv), returncode=code)


class _PatchedRun:
    def __init__(self, fake):
        self.fake = fake

    def __enter__(self):
        self.original = release_gate.run.run
        release_gate.run.run = self.fake
        return self.fake

    def __exit__(self, *exc):
        release_gate.run.run = self.original
        return False


def _call(fake):
    buf = io.StringIO()
    with _PatchedRun(fake), redirect_stdout(buf):
        rc = release_gate.auto_release(REPO_ROOT, "jhangyu/Halcyon", "main")
    return rc, buf.getvalue()


class VersionParsingTestCase(unittest.TestCase):
    def test_reads_semantic_version_without_build_number(self):
        version = release_gate.read_pubspec_version(REPO_ROOT)
        self.assertRegex(
            version,
            r"^[0-9]+\.[0-9]+\.[0-9]+$",
            "the tag must be the semantic version alone: pubspec's `+<build>` "
            "suffix is not part of a release tag",
        )

    def test_missing_version_line_raises(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "pubspec.yaml").write_text("name: halcyon\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                release_gate.read_pubspec_version(Path(tmp))


class SkipPathTestCase(unittest.TestCase):
    """AC2: an existing tag means skip cleanly — rc 0, loud line, no dispatch."""

    def test_existing_tag_skips_without_dispatch(self):
        fake = FakeRun([0])  # gh api ... -> tag exists
        rc, out = _call(fake)
        self.assertEqual(rc, 0)
        self.assertIn("AUTO-RELEASE-SKIP", out)
        self.assertEqual(len(fake.calls), 1, f"expected only the tag probe, got {fake.calls!r}")
        self.assertNotIn("workflow", fake.calls[0])

    def test_tag_probe_uses_the_exact_ref_endpoint(self):
        """`git/refs/tags/<t>` (plural) prefix-matches and would report v1.0.3
        as existing when asked about v1.0.30; `git/ref/tags/<t>` does not."""
        fake = FakeRun([0])
        _call(fake)
        probe = fake.calls[0]
        version = release_gate.read_pubspec_version(REPO_ROOT)
        self.assertEqual(probe[:2], ["gh", "api"])
        self.assertEqual(probe[2], f"repos/jhangyu/Halcyon/git/ref/tags/v{version}")


class DispatchPathTestCase(unittest.TestCase):
    def test_absent_tag_dispatches_release_workflow_with_publish_true(self):
        fake = FakeRun([1, 0])  # tag absent, then a successful dispatch
        rc, out = _call(fake)
        self.assertEqual(rc, 0)
        self.assertIn("AUTO-RELEASE-DISPATCH", out)
        self.assertIn("AUTO-RELEASE-OK", out)
        self.assertEqual(len(fake.calls), 2)
        dispatch = fake.calls[1]
        version = release_gate.read_pubspec_version(REPO_ROOT)
        self.assertEqual(dispatch[:4], ["gh", "workflow", "run", "release.yml"])
        self.assertIn(f"version=v{version}", dispatch)
        self.assertIn("publish=true", dispatch)
        self.assertIn("--ref", dispatch)

    def test_failed_dispatch_is_reported_as_failure(self):
        fake = FakeRun([1, 1])
        rc, out = _call(fake)
        self.assertNotEqual(rc, 0, "a failed dispatch must not be swallowed")
        self.assertIn("ERROR", out)


if __name__ == "__main__":
    unittest.main()
