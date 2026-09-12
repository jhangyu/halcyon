"""Mechanical checks for WI-7 (multi-symbol FFI probe) and WI-9 (macos-x64
Rosetta rejection, OQ-C3).

stdlib only (G-11): no dart/flutter subprocess here — that is covered by the
red/green artefacts captured against the real shipped decoder
(docs/logs/2026-09-12/{red,green}-ceyx-symbols.txt) and by CI's own
assert-capabilities run. This file is a static/text scan plus an in-process
import of ci.assertions / ci.targets, matching test_policy.py's approach.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
CI_PKG_DIR = REPO_ROOT / "scripts" / "ci"
PROBE_DART = CI_PKG_DIR / "probe" / "ffi_probe.dart"

if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))

import ci.assertions as assertions  # noqa: E402
import ci.targets as targets  # noqa: E402


class FfiProbeMultiSymbolTest(unittest.TestCase):
    """Step 7.1: ffi_probe.dart accepts N trailing symbols."""

    def setUp(self):
        self.source = PROBE_DART.read_text(encoding="utf-8")

    def test_zero_args_is_usage_error_not_symbol_count(self):
        # args.isEmpty is the ONLY usage-error guard left (clause 7): a
        # library path is still mandatory, but the old `args.length > 2`
        # upper bound must be gone so N symbols are accepted.
        self.assertIn("args.isEmpty", self.source)
        self.assertNotIn("args.length > 2", self.source)

    def test_symbols_default_to_single_historical_symbol(self):
        self.assertIn("args.length > 1 ? args.sublist(1)", self.source)
        self.assertIn("const [_defaultSymbol]", self.source)

    def test_failure_names_every_unresolved_symbol_not_just_first(self):
        # The loop must accumulate into a list and NOT exit() inside the
        # catch block, so one bad symbol can't short-circuit reporting on
        # the rest (clause 7's "exit 1 naming EVERY unresolved symbol").
        self.assertIn("unresolved.add(", self.source)
        loop_match = re.search(
            r"for \(final symbol in symbols\) \{(.*?)\n  \}", self.source, re.S
        )
        self.assertIsNotNone(loop_match, "expected a for-loop over symbols")
        self.assertNotIn("exit(", loop_match.group(1))

    def test_exit_codes_unchanged(self):
        self.assertIn("exit(2)", self.source)  # usage
        self.assertIn("exit(1)", self.source)  # PROBE-FAIL
        self.assertIn("exit(0)", self.source)  # all resolved


class HCeyxSymbolsRecordTest(unittest.TestCase):
    """Step 7.2/7.3: the H-CEYX-SYMBOLS assertion record and its impl."""

    def test_validate_suite_passes(self):
        assertions.validate_suite()  # raises on any missing mandatory field

    def test_record_present_and_valid_on_all_three_platforms(self):
        record = assertions.SUITE["H-CEYX-SYMBOLS"]
        self.assertEqual(record.id, "H-CEYX-SYMBOLS")
        self.assertEqual(record.valid_on, ("macos", "linux", "windows"))

    def test_measures_and_expected_are_built_from_the_symbols_tuple(self):
        record = assertions.SUITE["H-CEYX-SYMBOLS"]
        for symbol in assertions.CEYX_SYMBOLS:
            self.assertIn(symbol, record.measures)
            self.assertIn(symbol, record.expected)

    def test_why_valid_cites_the_historical_oq1_not_this_campaigns_oqc1(self):
        record = assertions.SUITE["H-CEYX-SYMBOLS"]
        self.assertIn("OQ-1 ruling c", record.why_valid)
        self.assertIn("NOT this", record.why_valid)

    def test_registered_in_implementations_dispatch(self):
        self.assertIn("H-CEYX-SYMBOLS", assertions._IMPLEMENTATIONS)
        self.assertIs(
            assertions._IMPLEMENTATIONS["H-CEYX-SYMBOLS"], assertions._assert_ceyx_symbols
        )

    def test_exactly_one_dart_run_call_site(self):
        # Clause 9: _run_probe is shared, not duplicated, so there must be
        # exactly one subprocess invocation building a `dart run` argv.
        source = (CI_PKG_DIR / "assertions.py").read_text(encoding="utf-8")
        self.assertEqual(source.count('dart, "run"'), 1)

    def test_sized_symbol_and_ceyx_symbols_share_run_probe(self):
        # Both wrappers must call the same shared helper, not separate copies.
        sized_src = assertions._assert_sized_symbol.__code__.co_names
        ceyx_src = assertions._assert_ceyx_symbols.__code__.co_names
        self.assertIn("_run_probe", sized_src)
        self.assertIn("_run_probe", ceyx_src)


class TargetsAssertionListsTest(unittest.TestCase):
    """Step 7.4 (clauses 10, 11, 13) and Step 9.4 (clause 17)."""

    def test_h_ceyx_symbols_on_macos_linux_windows_not_macos_x64(self):
        expected = {"macos": True, "linux": True, "windows": True, "macos-x64": False}
        for target, want in expected.items():
            with self.subTest(target=target):
                self.assertEqual(
                    "H-CEYX-SYMBOLS" in targets.TARGETS[target]["assertions"], want
                )

    def test_h_ceyx_symbols_nm_on_macos_macos_x64_linux_not_windows(self):
        expected = {"macos": True, "macos-x64": True, "linux": True, "windows": False}
        for target, want in expected.items():
            with self.subTest(target=target):
                self.assertEqual(
                    "H-CEYX-SYMBOLS-NM" in targets.TARGETS[target]["assertions"], want
                )

    def test_h_sized_symbol_nm_record_untouched_by_this_work(self):
        # Clause 13: valid_on must remain exactly (macos, linux) -- no
        # windows string anywhere in that record.
        record = assertions.SUITE["H-SIZED-SYMBOL-NM"]
        self.assertEqual(record.valid_on, ("macos", "linux"))
        self.assertNotIn("windows", record.valid_on)

    def test_macos_x64_assert_platform_and_runs_on_unchanged(self):
        # Clause 17 (WI-9): documentation-only change, architecture is not
        # smuggled in as a platform name.
        entry = targets.TARGETS["macos-x64"]
        self.assertEqual(entry["assert_platform"], "macos")
        self.assertEqual(entry["runs_on"], "macos-14")

    def test_rosetta_rejection_comment_present_exactly_once(self):
        source = (CI_PKG_DIR / "targets.py").read_text(encoding="utf-8")
        hits = [line for line in source.splitlines() if "Rosetta" in line]
        self.assertEqual(len(hits), 1, hits)
        idx = source.index(hits[0])
        block = source[idx : idx + 400]
        self.assertIn("2026-09-12", block)
        self.assertIn("OQ-C3", block)


if __name__ == "__main__":
    unittest.main()
