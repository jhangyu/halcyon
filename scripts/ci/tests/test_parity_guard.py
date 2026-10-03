import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))

from ci import parity_guard as pg  # noqa: E402


def _lister(files):
    return lambda root, prefix: [p for p in files if p.startswith(prefix)]


class TestParityGuard(unittest.TestCase):
    def _tree(self, tmp, files):
        for rel, text in files.items():
            path = Path(tmp) / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return pg.scan(Path(tmp), lister=_lister(list(files)))

    def test_unregistered_dart_guard_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            found = self._tree(tmp, {"lib/x.dart": "final w = Platform.isWindows;\n"})
            problems, _ = pg.check(found, {}, require_closed=False)
        self.assertEqual(len(problems), 1)
        self.assertIn("UNREGISTERED", problems[0])

    def test_count_change_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            found = self._tree(tmp, {"lib/x.dart": "Platform.isWindows;\nPlatform.isMacOS;\n"})
            reg = {"lib/x.dart": {"guard_lines": 1, "role": "adapter", "contract": "c"}}
            problems, _ = pg.check(found, reg, require_closed=False)
        self.assertTrue(any("GUARD COUNT CHANGED" in p for p in problems))

    def test_stale_entry_fails(self):
        reg = {"lib/gone.dart": {"guard_lines": 1, "role": "adapter", "contract": "c"}}
        problems, _ = pg.check({}, reg, require_closed=False)
        self.assertTrue(any("STALE ENTRY" in p for p in problems))

    def test_illegal_role_fails(self):
        found = {"lib/x.dart": 1}
        reg = {"lib/x.dart": {"guard_lines": 1, "role": "CLASSIFY", "contract": "CLASSIFY"}}
        problems, _ = pg.check(found, reg, require_closed=False)
        self.assertTrue(any("ILLEGAL ROLE" in p for p in problems))

    def test_require_closed_fails_on_open_forks(self):
        found = {"lib/x.dart": 1}
        reg = {"lib/x.dart": {"guard_lines": 1, "role": "fork-host", "contract": "c",
                              "open_forks": ["B6"]}}
        problems, open_ids = pg.check(found, reg, require_closed=True)
        self.assertEqual(open_ids, ["B6"])
        self.assertTrue(any("OPEN FORKS" in p for p in problems))

    def test_dart_patterns(self):
        for line in ("if (Platform.isWindows) {", "    if (dart.library.ffi) 'a.dart';", "!kIsWeb &&"):
            self.assertTrue(pg.DART_GUARD.search(line), line)
        self.assertIsNone(pg.DART_GUARD.search("final platformName = 'x';"))

    def test_real_tree_matches_registry(self):
        found = pg.scan(pg.REPO_ROOT)
        problems, _ = pg.check(found, pg.REGISTRY, require_closed=pg.REQUIRE_CLOSED)
        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
