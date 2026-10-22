"""update_ceyx_pin_latest's asset download must reuse the per-tag cache and
publish atomically. No network: build_apps.download_with_progress is replaced."""

from __future__ import annotations

import sys
import tempfile
import types
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import build_apps  # noqa: E402


class PinDownloadCacheTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.layout = types.SimpleNamespace(halcyon=Path(self._td.name))
        self.calls = []
        self._orig = build_apps.download_with_progress
        build_apps.download_with_progress = self._fake
        self.addCleanup(setattr, build_apps, "download_with_progress", self._orig)

    def _fake(self, url, dest, failure_hints=None):
        self.calls.append(Path(dest))
        Path(dest).write_bytes(b"payload")

    def _cache(self):
        return build_apps.ceyx_cache_dir(self.layout, "v9.9.9")

    def test_cached_asset_is_not_downloaded_again(self):
        self._cache().mkdir(parents=True)
        (self._cache() / "a.tar.gz").write_bytes(b"cached")
        path, digest = build_apps.download_ceyx_release_asset(self.layout, "v9.9.9", "a.tar.gz")
        self.assertEqual(self.calls, [])
        self.assertEqual(path.read_bytes(), b"cached")
        self.assertEqual(digest, build_apps.sha256_of(path))

    def test_download_goes_to_temp_name_then_renamed(self):
        path, _ = build_apps.download_ceyx_release_asset(self.layout, "v9.9.9", "a.tar.gz")
        self.assertEqual(len(self.calls), 1)
        self.assertNotEqual(self.calls[0], path)
        self.assertEqual(path.read_bytes(), b"payload")
        self.assertEqual([p.name for p in self._cache().iterdir()], ["a.tar.gz"])


if __name__ == "__main__":
    unittest.main()
