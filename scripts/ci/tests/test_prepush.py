"""prepush.judge_tests: the quarantine may explain a red tests step only when
EVERY failure in EVERY red shard is a test inside a QUARANTINED_FILES file.
stdlib only."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
from ci import prepush  # noqa: E402

CLONE = Path("C:/scratch/Halcyon") if sys.platform == "win32" else Path("/scratch/Halcyon")
QUARANTINED_FILE = next(iter(prepush.QUARANTINED_FILES))
QUARANTINED = f"{QUARANTINED_FILE}: any test name in that file"


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

    def test_any_failure_inside_a_quarantined_file_is_flaky_not_red(self):
        rc, flaky, _ = self._run([(1, _fail_line(QUARANTINED)), (0, "")], raw_rc=1)
        self.assertEqual((rc, flaky), (0, 1))

    def test_an_unlisted_file_stays_red_even_beside_a_quarantined_one(self):
        text = _fail_line(QUARANTINED) + "\n" + _fail_line("test/x_test.dart: a real failure")
        rc, flaky, lines = self._run([(1, text)], raw_rc=1)
        self.assertEqual((rc, flaky), (1, 1))
        self.assertIn("TESTS-RED test/x_test.dart: a real failure", lines)

    def test_a_quarantined_file_that_fails_to_load_stays_red(self):
        line = f"00:00 +0 -1: loading {CLONE.as_posix()}/{QUARANTINED_FILE} [E]"
        rc, flaky, _ = self._run([(1, line)], raw_rc=1)
        self.assertEqual((rc, flaky), (1, 0))

    def test_red_shard_without_a_named_failure_is_red(self):
        rc, _, _ = self._run([(1, "Error: Compilation failed.")], raw_rc=1)
        self.assertEqual(rc, 1)

    def test_nonzero_runner_rc_without_a_red_shard_is_red(self):
        rc, _, _ = self._run([(0, "")], raw_rc=2)
        self.assertEqual(rc, 1)

    def test_all_green_is_green(self):
        self.assertEqual(self._run([(0, "")], raw_rc=0)[:2], (0, 0))

    def test_every_quarantined_file_exists_and_cites_evidence(self):
        repo = Path(__file__).resolve().parents[3]
        for path, evidence in prepush.QUARANTINED_FILES.items():
            with self.subTest(path=path):
                self.assertTrue(path.startswith("test/") and path.endswith("_test.dart"))
                self.assertTrue((repo / path).is_file(), f"{path} does not exist")
                self.assertRegex(evidence, r"(run[0-4][^,]*\.log|quiet-tests\.log|"
                                           r"serial-diag\.txt|isolate-\w+\.txt)")

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
