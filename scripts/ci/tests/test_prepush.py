"""prepush.judge_tests: the quarantine may explain a red tests step only when
EVERY failure in EVERY red shard is a timing-sized failure inside a
QUARANTINED_FILES file (results read from the shard's JSON report).
stdlib only."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
from ci import prepush  # noqa: E402

CLONE = Path("C:/scratch/Halcyon") if sys.platform == "win32" else Path("/scratch/Halcyon")
LISTED = next(iter(prepush.QUARANTINED_FILES))


def _report(results):
    """JSON-reporter lines for [(file, name, outcome[, hidden])]."""
    events, suites = [], {}
    for i, (path, name, outcome, *hidden) in enumerate(results):
        if path not in suites:
            suites[path] = len(suites)
            events.append({"type": "suite", "suite": {"id": suites[path],
                                                      "path": f"{CLONE.as_posix()}/{path}"}})
        events.append({"type": "testStart", "test": {"id": 100 + i, "name": name,
                                                     "suiteID": suites[path]}})
        if outcome == "no-done":  # started, then the file crashed before testDone
            continue
        events.append({"type": "testDone", "testID": 100 + i, "hidden": bool(hidden),
                       "skipped": outcome == "skip",
                       "result": "failure" if outcome == "fail" else "success"})
        if outcome == "late-fail":  # "This test failed after it had already completed"
            events.append({"type": "error", "testID": 100 + i, "isFailure": False,
                           "error": "This test failed after it had already completed."})
    return "\n".join(json.dumps(e) for e in events)


def _all_listed_pass(n=4):
    return [(f, f"t{k}", "pass") for f in prepush.QUARANTINED_FILES for k in range(n)]


class TestJudgeTests(unittest.TestCase):
    def _run(self, shards, raw_rc):
        """shards: [(rc, results or None for a missing JSON report)]."""
        with tempfile.TemporaryDirectory() as tmp:
            out = []
            for i, (rc, results) in enumerate(shards):
                log = Path(tmp, f"tests-s{i}.txt")
                log.write_text("", encoding="utf-8")
                if results is not None:
                    log.with_suffix(".json").write_text(_report(results), encoding="utf-8")
                out.append(f"SHARD s{i}: files=1 declared=1 executed=1 passed=0 failed=1 "
                           f"skipped=0 elapsed=1.0s load=unavailable RC={rc} log={log}")
            return prepush.judge_tests("\n".join(out), raw_rc, CLONE)

    def test_a_timing_sized_failure_inside_a_listed_file_is_flaky_not_red(self):
        rc, flaky, _ = self._run([(1, [(LISTED, "flaky one", "fail")]),
                                  (0, _all_listed_pass())], raw_rc=1)
        self.assertEqual((rc, flaky), (0, 1))

    def test_an_unlisted_file_stays_red_even_beside_a_listed_one(self):
        results = [(LISTED, "flaky one", "fail"), ("test/x_test.dart", "a real failure", "fail")]
        rc, flaky, lines = self._run([(1, results), (0, _all_listed_pass())], raw_rc=1)
        self.assertEqual((rc, flaky), (1, 1))
        self.assertIn("TESTS-RED test/x_test.dart: a real failure", lines)

    def test_setupall_failure_in_a_listed_file_is_red(self):
        results = [(LISTED, "group (setUpAll)", "fail", True)]
        rc, flaky, _ = self._run([(1, results), (0, _all_listed_pass())], raw_rc=1)
        self.assertEqual((rc, flaky), (1, 0))

    def test_teardownall_failure_in_a_listed_file_is_red(self):
        results = [(LISTED, "(tearDownAll)", "fail", True)]
        rc, _, _ = self._run([(1, results), (0, _all_listed_pass())], raw_rc=1)
        self.assertEqual(rc, 1)

    def test_a_listed_file_that_fails_to_load_is_red(self):
        results = [(LISTED, f"loading {CLONE.as_posix()}/{LISTED}", "fail", True)]
        rc, flaky, _ = self._run([(1, results), (0, _all_listed_pass())], raw_rc=1)
        self.assertEqual((rc, flaky), (1, 0))

    def test_a_listed_file_that_ran_no_tests_is_red(self):
        others = [r for r in _all_listed_pass() if r[0] != LISTED]
        rc, _, lines = self._run([(0, others + [(LISTED, "all skipped", "skip")])], raw_rc=0)
        self.assertEqual(rc, 1)
        self.assertIn(f"TESTS-RED quarantined file {LISTED} ran no tests", lines)

    def test_more_than_half_of_a_listed_file_failing_is_red(self):
        others = [r for r in _all_listed_pass() if r[0] != LISTED]
        mine = [(LISTED, "a", "fail"), (LISTED, "b", "fail"), (LISTED, "c", "pass")]
        rc, flaky, _ = self._run([(1, others + mine)], raw_rc=1)
        self.assertEqual((rc, flaky), (1, 2))

    def test_exactly_half_failing_is_still_timing_territory(self):
        others = [r for r in _all_listed_pass() if r[0] != LISTED]
        mine = [(LISTED, "a", "fail"), (LISTED, "b", "pass")]
        rc, flaky, _ = self._run([(1, others + mine)], raw_rc=1)
        self.assertEqual((rc, flaky), (0, 1))

    def test_an_error_after_a_passing_testdone_is_a_failure(self):
        results = [("test/x_test.dart", "passed then errored", "late-fail")]
        rc, _, lines = self._run([(1, results), (0, _all_listed_pass())], raw_rc=1)
        self.assertEqual(rc, 1)
        self.assertIn("TESTS-RED test/x_test.dart: passed then errored", lines)

    def test_a_started_test_with_no_testdone_is_a_failure(self):
        results = [("test/x_test.dart", "never finished", "no-done")]
        self.assertEqual(prepush.test_results(_report(results), CLONE),
                         [("test/x_test.dart", "never finished", "fail")])
        rc, _, lines = self._run([(1, results), (0, _all_listed_pass())], raw_rc=1)
        self.assertEqual(rc, 1)
        self.assertIn("TESTS-RED test/x_test.dart: never finished", lines)

    def test_a_shard_without_its_json_report_is_red(self):
        rc, _, _ = self._run([(0, None), (0, _all_listed_pass())], raw_rc=0)
        self.assertEqual(rc, 1)

    def test_red_shard_without_a_failing_test_is_red(self):
        rc, _, _ = self._run([(1, _all_listed_pass())], raw_rc=1)
        self.assertEqual(rc, 1)

    def test_nonzero_runner_rc_without_a_red_shard_is_red(self):
        rc, _, _ = self._run([(0, _all_listed_pass())], raw_rc=2)
        self.assertEqual(rc, 1)

    def test_all_green_is_green(self):
        self.assertEqual(self._run([(0, _all_listed_pass())], raw_rc=0)[:2], (0, 0))

    def test_every_quarantined_file_exists_and_cites_evidence(self):
        repo = Path(__file__).resolve().parents[3]
        for path, evidence in prepush.QUARANTINED_FILES.items():
            with self.subTest(path=path):
                self.assertTrue(path.startswith("test/") and path.endswith("_test.dart"))
                self.assertTrue((repo / path).is_file(), f"{path} does not exist")
                self.assertRegex(evidence, r"(run[0-4][^,]*\.log|quiet-tests\.log|"
                                           r"serial-diag\.txt|isolate-\w+\.txt|v-r3D-tests\.log|m2-prepush(-\d)?\.txt)")

REPO = Path(__file__).resolve().parents[3]
WORKFLOWS = REPO / ".github" / "workflows"


class TestGateSafety(unittest.TestCase):
    def test_a_workflow_running_prepush_is_a_lint_error_never_a_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "x.yml").write_text(
                "jobs:\n  gate:\n    steps:\n      - name: gate\n"
                "        run: python3 scripts/ci.py prepush\n",
                encoding="utf-8")
            steps, _, errors = prepush.derive_plan(Path(tmp), host=("windows", "x86_64"))
        self.assertEqual(steps, [])
        self.assertTrue(any("prepush" in e for e in errors), errors)

    def test_workdir_without_marker_is_never_deleted(self):
        with tempfile.TemporaryDirectory() as tmp:
            victim = Path(tmp, "not-ours")
            victim.mkdir()
            Path(victim, "precious.txt").write_text("x", encoding="utf-8")
            with self.assertRaises(RuntimeError):
                prepush.remove_workdir(victim)
            self.assertTrue(Path(victim, "precious.txt").is_file())
            Path(victim, prepush.WORKDIR_MARKER).write_text("", encoding="utf-8")
            prepush.remove_workdir(victim)
            self.assertFalse(victim.exists())

    def test_single_step_prints_partial_never_the_full_summary(self):
        import contextlib  # noqa: PLC0415
        import io  # noqa: PLC0415

        with tempfile.TemporaryDirectory() as tmp:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
                rc = prepush.main(REPO, step="selftest", workdir=Path(tmp, "none"),
                                  log_dir=Path(tmp, "logs"))
        self.assertEqual(rc, 1)
        self.assertIn("PREPUSH-PARTIAL step=selftest", buf.getvalue())
        self.assertNotIn("PREPUSH-SUMMARY", buf.getvalue())


class TestContainerLeg(unittest.TestCase):
    def test_container_leg_runs_only_its_target_steps(self):
        runner = "ubuntu-24.04-arm"
        steps, _, errors = prepush.derive_plan(WORKFLOWS, host=prepush.targets.RUNNER_HOST[runner])
        self.assertEqual(errors, [])
        names = [n for n, _ in prepush.leg_steps(steps)]
        self.assertIn("build-linux-arm", names)
        self.assertIn("assert-capabilities-linux-arm", names)
        self.assertFalse(any(n in ("selftest", "verify") for n in names), names)

    def test_no_docker_is_a_counted_skip(self):
        from unittest import mock  # noqa: PLC0415

        with tempfile.TemporaryDirectory() as tmp:
            layout = prepush.Layout(REPO, Path(tmp, "w"))
            log = Path(tmp, "container.txt")
            with mock.patch.object(prepush, "docker_unavailable_reason", return_value="no docker"):
                rc = prepush._step_container(layout, "ubuntu-24.04-arm", log)
            self.assertEqual((rc, layout.skipped), (0, 1))
            self.assertIn("PREPUSH-SKIP container-ubuntu-24.04-arm", log.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
