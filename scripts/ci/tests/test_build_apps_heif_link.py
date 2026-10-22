"""decoder_links_heif: green when the PE import table names heif.dll (static or
delay-loaded), red when it does not. Fixtures reuse test_binfmt's PE builder."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))

from ci.tests.test_binfmt import _pe  # noqa: E402
import build_apps  # noqa: E402


class DecoderLinksHeifTest(unittest.TestCase):
    def test_static_import_is_found(self):
        self.assertTrue(build_apps.decoder_links_heif(_pe(static=["KERNEL32.dll", "heif.dll"])))

    def test_delay_import_is_found(self):
        self.assertTrue(build_apps.decoder_links_heif(_pe(delayed=["HEIF.DLL"])))

    def test_absent_is_red(self):
        self.assertFalse(build_apps.decoder_links_heif(_pe(static=["KERNEL32.dll"], delayed=["libde265.dll"])))

    def test_non_pe_raises(self):
        with self.assertRaises(ValueError):
            build_apps.decoder_links_heif(b"\x7fELF")


if __name__ == "__main__":
    unittest.main()
