"""prepush.judge_tests: the quarantine may explain a red tests step only when
EVERY failure in EVERY red shard is an enumerated QUARANTINE entry. stdlib only."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
from ci import prepush  # noqa: E402

CLONE = Path("C:/scratch/Halcyon") if sys.platform == "win32" else Path("/scratch/Halcyon")
QUARANTINED = next(iter(prepush.QUARANTINE))


def _fail_line(name):
    return f"00:08 +77 ~1 -1: {CLONE.as_posix()}/{name} [E]"


class TestJudgeTests(unittest.TestCase):
    def _run(self, shard_logs, raw_rc):
        with tempfile.TemporaryDirectory() as tmp:
            out = []
            for i, (rc, text) in enumerate(shard_logs):
                log = Path(tmp, f"tests-s{i}.txt")
                log.write_text(text, encoding="utf-8")
                out.append(f"SHARD s{i}: files=1 declared=1 executed=1 passed=0 failed=1 "
                           f"skipped=0 elapsed=1.0s load=unavailable RC={rc} log={log}")
            return prepush.judge_tests("\n".join(out), raw_rc, CLONE)

    def test_only_quarantined_failures_are_flaky_not_red(self):
        rc, flaky, _ = self._run([(1, _fail_line(QUARANTINED)), (0, "")], raw_rc=1)
        self.assertEqual((rc, flaky), (0, 1))

    def test_an_unlisted_failure_stays_red_even_beside_a_quarantined_one(self):
        text = _fail_line(QUARANTINED) + "\n" + _fail_line("test/x_test.dart: a real failure")
        rc, flaky, lines = self._run([(1, text)], raw_rc=1)
        self.assertEqual((rc, flaky), (1, 1))
        self.assertIn("TESTS-RED test/x_test.dart: a real failure", lines)

    def test_red_shard_without_a_named_failure_is_red(self):
        rc, _, _ = self._run([(1, "Error: Compilation failed.")], raw_rc=1)
        self.assertEqual(rc, 1)

    def test_nonzero_runner_rc_without_a_red_shard_is_red(self):
        rc, _, _ = self._run([(0, "")], raw_rc=2)
        self.assertEqual(rc, 1)

    def test_all_green_is_green(self):
        self.assertEqual(self._run([(0, "")], raw_rc=0)[:2], (0, 0))

    def test_every_quarantine_entry_cites_evidence(self):
        for name, evidence in prepush.QUARANTINE.items():
            with self.subTest(name=name):
                self.assertTrue(name.startswith("test/") and ".dart: " in name)
                self.assertRegex(evidence, r"(run0-red\.log|isolate-rerun\.txt)")


if __name__ == "__main__":
    unittest.main()
