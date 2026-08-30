"""Golden argv rendering + Windows path lints (Plan §WP-E / Spec §4.8).

What this proves: ``--print-plan``'s rendered argv is a pure function of the
data in ``scripts/ci/targets.py``, so a flag regression (a dropped
``--fetch-native``, a changed archive name) is caught pre-commit on *any*
host — the Windows argv can be asserted from a macOS laptop with no Windows
runner.

What this does NOT prove, stated per the plan's own caveat: nothing here
establishes Windows *runtime* behaviour (whether the interpreter is on PATH,
whether the DLL actually loads, etc). It eliminates the flag/path-mangling
families statically; the rest still needs a real runner (WP-F step F5/F7).

Each test independently recomputes the expected argv straight from
``targets.py`` data (not by re-reading the golden file back at itself) and
also compares against the frozen ``golden/<target>.txt`` file, so a golden
file that silently drifted from ``targets.py`` is caught too.
"""

from __future__ import annotations

import ast
import io
import re
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

GOLDEN_DIR = Path(__file__).resolve().parent / "golden"

# Plan §3/WP-E "print_plan() prints, per phase, `PLAN <phase>: <argv list repr>`".
PLAN_LINE_RE = re.compile(r"^PLAN (\w[\w-]*): (\[.*\])\s*$")

TARGET_NAMES = ["macos", "windows", "linux", "android-apk", "web"]


def _capture_print_plan(target):
    """Runs phases.print_plan(REPO_ROOT, target), returns (rc, captured_stdout).

    Imported lazily (not at module top-level) so this test module can itself
    be *collected* and *run* — and correctly report a red/NotImplementedError
    state — even before WP-B lands scripts/ci/phases.py (E1's red half of the
    red -> green evidence requirement).
    """
    import ci.phases as phases  # noqa: PLC0415 (intentional lazy import, see above)

    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = phases.print_plan(REPO_ROOT, target)
    return rc, buf.getvalue()


def _parse_plan_lines(output):
    """{phase: argv_list} parsed from ``PLAN <phase>: <repr>`` lines."""
    parsed = {}
    for line in output.splitlines():
        m = PLAN_LINE_RE.match(line)
        if m:
            parsed[m.group(1)] = ast.literal_eval(m.group(2))
    return parsed


def _expected_build_argv(target):
    """Independently recomputed from targets.py — G-8/G-5: build_flags are the
    only per-platform fact, everything else is the fixed command shape."""
    import ci.targets as targets  # noqa: PLC0415

    spec = targets.spec(target)
    return ["python3", "scripts/build_apps.py", target, *spec["build_flags"]]


def _normalize_build_argv(argv):
    """G-8 requires ``build()``/``print_plan()`` to render
    ``os.fspath(Path(repo_root, "scripts", "build_apps.py").resolve())`` — an
    *absolute* path whose text is host-native (POSIX on this runner, ``C:\\``
    on a real Windows one). That element is therefore not comparable across
    hosts byte-for-byte; every other element is a pure string straight out of
    ``targets.py`` and IS comparable. Normalize just that one element back to
    its repo-root-relative form so golden files stay host-independent."""
    normalized = []
    for element in argv:
        if element.endswith(str(Path("scripts", "build_apps.py"))) and Path(element).is_absolute():
            normalized.append("scripts/build_apps.py")
        else:
            normalized.append(element)
    return normalized


DRIVE_LETTER_RE = re.compile(r"^[A-Za-z]:[\\/]")


class GoldenArgvTestCase(unittest.TestCase):
    """Base: skip (not fail) if phases.py is not yet implemented — see E1."""

    def _plans_for(self, target):
        try:
            rc, output = _capture_print_plan(target)
        except (ModuleNotFoundError, ImportError) as exc:
            self.skipTest(f"scripts/ci/phases.py not present yet (WP-B pending): {exc}")
        except NotImplementedError as exc:
            self.skipTest(f"phases.print_plan not yet implemented (WP-B pending): {exc}")
        self.assertEqual(rc, 0, f"--print-plan --target {target} must exit 0, got {rc}")
        plans = _parse_plan_lines(output)
        self.assertIn(
            "build",
            plans,
            f"--print-plan output for {target!r} has no 'PLAN build: ...' line:\n{output}",
        )
        return plans


def _make_golden_test(target):
    def test(self):
        plans = self._plans_for(target)
        rendered_build = _normalize_build_argv(plans["build"])

        golden_path = GOLDEN_DIR / f"{target}.txt"
        self.assertTrue(golden_path.is_file(), f"missing golden file {golden_path}")
        golden_argv = ast.literal_eval(golden_path.read_text(encoding="utf-8").strip())

        self.assertEqual(
            rendered_build,
            golden_argv,
            f"rendered build argv for {target!r} diverged from {golden_path}:\n"
            f"  rendered: {rendered_build!r}\n"
            f"  golden:   {golden_argv!r}",
        )
        self.assertEqual(
            rendered_build,
            _expected_build_argv(target),
            f"rendered build argv for {target!r} diverged from targets.py itself "
            f"(golden file and targets.py are both being compared independently)",
        )

    test.__name__ = f"test_golden_{target.replace('-', '_')}"
    return test


def _install_golden_tests():
    for target in TARGET_NAMES:
        setattr(
            GoldenArgvTestCase,
            f"test_golden_{target.replace('-', '_')}",
            _make_golden_test(target),
        )


_install_golden_tests()


class WindowsBuildFlagTestCase(GoldenArgvTestCase):
    def test_windows_has_fetch_native(self):
        plans = self._plans_for("windows")
        self.assertIn(
            "--fetch-native",
            plans["build"],
            "windows build argv must contain --fetch-native (release.yml:96-101)",
        )

    def test_macos_has_no_fetch_native(self):
        plans = self._plans_for("macos")
        self.assertNotIn(
            "--fetch-native",
            plans["build"],
            "macos ships six committed dylibs and must never fetch native libs",
        )


class WindowsPathLintTestCase(unittest.TestCase):
    """Zero-cost static lints over the WINDOWS target's stored data in
    ``targets.py`` (Spec §4.8) — these catch the drive-letter-eaten family
    (``D:/a/... -> \\d\\a\\...``) without needing a Windows host at all.

    Scope note: ``phases._build_argv`` renders one absolute path via
    ``os.fspath(Path(repo_root, ...).resolve())`` (G-8) — that element is
    necessarily host-native text (POSIX here, ``C:\\...`` on a real Windows
    runner) and is NOT the corruption class these lints exist to catch, so it
    is deliberately out of scope here (see ``_normalize_build_argv`` in the
    golden-argv tests above). What IS in scope, and what a real regression
    would look like: a hardcoded path-shaped **string literal** landing in
    ``targets.py``'s ``windows`` entry (``build_flags``, ``provision``,
    ``artifact_path``, ``archive_name``) — those strings are rendered
    verbatim into Windows argv/paths regardless of host, so a stray leading
    ``/`` or a mangled ``\\d\\a\\...`` shape there is a real, host-independent
    bug this test will catch on any platform this suite runs on."""

    def _windows_string_fields(self):
        import ci.targets as targets  # noqa: PLC0415

        spec = targets.spec("windows")
        fields = list(spec["build_flags"])
        for argv in spec["provision"]:
            fields.extend(argv)
        fields.append(spec["artifact_path"])
        fields.append(spec["archive_name"])
        return fields

    def test_no_element_begins_with_unix_absolute_slash(self):
        offenders = [f for f in self._windows_string_fields() if f.startswith("/")]
        self.assertEqual(
            offenders,
            [],
            f"windows target data in targets.py must never contain a bare "
            f"unix-style absolute path (the corrupted form of a drive-letter "
            f"path): {offenders!r}",
        )

    def test_no_mangled_rooted_path_without_drive_letter(self):
        """Catches the ``D:/a/... -> \\d\\a\\...`` shape directly: a single
        leading backslash with no drive letter ahead of it."""
        offenders = []
        for field in self._windows_string_fields():
            if field.startswith("\\") and not field.startswith("\\\\"):
                if not DRIVE_LETTER_RE.match(field):
                    offenders.append(field)
        self.assertEqual(
            offenders,
            [],
            f"windows target data contains a rooted path with no drive letter "
            f"— this is exactly the drive-letter-eaten corruption shape: {offenders!r}",
        )


if __name__ == "__main__":
    unittest.main()
