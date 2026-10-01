"""build_apps.py ceyx-fetch gate tests, relocated verbatim from test_policy.py
(2026-10-02). They must stay under scripts/ci/tests/: selftest discovers that
directory only (phases.selftest), so a test moved elsewhere leaves the gate."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
PIN_FILE = REPO_ROOT / "scripts" / "ceyx_release_pin.json"


def _build_apps_module():
    scripts_dir = REPO_ROOT / "scripts"
    if str(scripts_dir) not in sys.path:
        sys.path.insert(0, str(scripts_dir))
    import build_apps  # noqa: PLC0415

    return build_apps


class CeyxFetchGateTests(unittest.TestCase):
    """P4a (win-parity-plan.md): ceyx_fetch_is_due must re-fetch when a
    PRESENT destination artifact's sha256 mismatches the pin, not just when
    the artifact is absent. Frozen precedence order:
      1. args.fetch_native -> True
      2. args.native == "always" -> False
      3. auto -> True if any member artifact is ABSENT
      4. auto -> True if any PRESENT member artifact's sha256 != pinned digest
    """

    def _make_layout(self, decoder_dir):
        import types  # noqa: PLC0415

        return types.SimpleNamespace(decoder=decoder_dir)

    def _make_args(self, fetch_native=False, native="auto"):
        import types  # noqa: PLC0415

        return types.SimpleNamespace(fetch_native=fetch_native, native=native)

    def test_present_but_wrong_sha_triggers_refetch(self):
        import hashlib  # noqa: PLC0415
        import tempfile  # noqa: PLC0415

        build_apps = _build_apps_module()
        ft = "linux"
        spec = build_apps.CEYX_FETCH_SPECS[ft]
        with tempfile.TemporaryDirectory() as td:
            decoder_dir = Path(td)
            dest_dir = decoder_dir / spec["dest"]
            dest_dir.mkdir(parents=True)
            member = spec["members"][0]
            path = dest_dir / member["artifact"]
            path.write_bytes(b"not the pinned bytes")
            wrong_digest = hashlib.sha256(b"not the pinned bytes").hexdigest()
            pinned_digest = hashlib.sha256(b"the real pinned bytes").hexdigest()
            self.assertNotEqual(wrong_digest, pinned_digest)

            def fake_load_ceyx_pin():
                return (
                    "v0.0.0-test",
                    {
                        ft: {
                            "libraries": [
                                {"member": member["member"],
                                 "artifact": member["artifact"],
                                 "sha256": pinned_digest},
                            ],
                        },
                    },
                    {"asset": "artifacts.lock", "sha256": "ignored"},
                )

            orig = build_apps.load_ceyx_pin
            build_apps.load_ceyx_pin = fake_load_ceyx_pin
            try:
                due = build_apps.ceyx_fetch_is_due(
                    ft, self._make_layout(decoder_dir), self._make_args())
            finally:
                build_apps.load_ceyx_pin = orig
            self.assertTrue(due, "mismatched present artifact must trigger a refetch")

    def test_present_and_matching_sha_does_not_refetch(self):
        import hashlib  # noqa: PLC0415
        import tempfile  # noqa: PLC0415

        build_apps = _build_apps_module()
        ft = "linux"
        spec = build_apps.CEYX_FETCH_SPECS[ft]
        with tempfile.TemporaryDirectory() as td:
            decoder_dir = Path(td)
            dest_dir = decoder_dir / spec["dest"]
            dest_dir.mkdir(parents=True)
            member = spec["members"][0]
            path = dest_dir / member["artifact"]
            path.write_bytes(b"the real pinned bytes")
            pinned_digest = hashlib.sha256(b"the real pinned bytes").hexdigest()

            def fake_load_ceyx_pin():
                return (
                    "v0.0.0-test",
                    {
                        ft: {
                            "libraries": [
                                {"member": member["member"],
                                 "artifact": member["artifact"],
                                 "sha256": pinned_digest},
                            ],
                        },
                    },
                    {"asset": "artifacts.lock", "sha256": "ignored"},
                )

            orig = build_apps.load_ceyx_pin
            build_apps.load_ceyx_pin = fake_load_ceyx_pin
            try:
                due = build_apps.ceyx_fetch_is_due(
                    ft, self._make_layout(decoder_dir), self._make_args())
            finally:
                build_apps.load_ceyx_pin = orig
            self.assertFalse(due, "matching present artifact must not refetch")

    def test_fetch_native_flag_forces_true_regardless(self):
        import tempfile  # noqa: PLC0415

        build_apps = _build_apps_module()
        ft = "linux"
        spec = build_apps.CEYX_FETCH_SPECS[ft]
        with tempfile.TemporaryDirectory() as td:
            decoder_dir = Path(td)
            dest_dir = decoder_dir / spec["dest"]
            dest_dir.mkdir(parents=True)
            member = spec["members"][0]
            (dest_dir / member["artifact"]).write_bytes(b"anything")
            due = build_apps.ceyx_fetch_is_due(
                ft, self._make_layout(decoder_dir),
                self._make_args(fetch_native=True))
            self.assertTrue(due, "--fetch-native must force True regardless of hash state")

    def test_native_always_forces_false_regardless(self):
        import tempfile  # noqa: PLC0415

        build_apps = _build_apps_module()
        ft = "linux"
        spec = build_apps.CEYX_FETCH_SPECS[ft]
        with tempfile.TemporaryDirectory() as td:
            decoder_dir = Path(td)
            dest_dir = decoder_dir / spec["dest"]
            # Deliberately leave the artifact absent -- native=="always" must
            # win even over the absence branch.
            due = build_apps.ceyx_fetch_is_due(
                ft, self._make_layout(decoder_dir),
                self._make_args(native="always"))
            self.assertFalse(due, "native=='always' must force False regardless")

    def test_pin_entry_without_libraries_degrades_to_absent_only(self):
        """A pin asset entry with no (or empty) 'libraries' list must not hard
        fail the --check path (which stays network-free): ceyx_fetch_is_due
        degrades to the old absent-only staleness detection and returns False
        for a PRESENT artifact, regardless of its actual bytes."""
        import tempfile  # noqa: PLC0415

        build_apps = _build_apps_module()
        ft = "linux"
        spec = build_apps.CEYX_FETCH_SPECS[ft]
        with tempfile.TemporaryDirectory() as td:
            decoder_dir = Path(td)
            dest_dir = decoder_dir / spec["dest"]
            dest_dir.mkdir(parents=True)
            member = spec["members"][0]
            (dest_dir / member["artifact"]).write_bytes(b"whatever bytes are on disk")

            def fake_load_ceyx_pin_no_libraries():
                return (
                    "v0.0.0-test",
                    {ft: {"libraries": []}},
                    {"asset": "artifacts.lock", "sha256": "ignored"},
                )

            orig = build_apps.load_ceyx_pin
            build_apps.load_ceyx_pin = fake_load_ceyx_pin_no_libraries
            try:
                due = build_apps.ceyx_fetch_is_due(
                    ft, self._make_layout(decoder_dir), self._make_args())
            finally:
                build_apps.load_ceyx_pin = orig
            self.assertFalse(
                due,
                "an entry with no per-artifact digests must degrade to "
                "absent-only detection, not force a refetch or hard-fail")

    def test_member_without_digest_degrades_to_no_refetch_for_that_artifact(self):
        """A 'libraries' entry present for the fetch-target but missing a
        digest for THIS SPECIFIC member must skip the checksum-mismatch check
        for that artifact only (warn-and-continue), not force a refetch."""
        import tempfile  # noqa: PLC0415

        build_apps = _build_apps_module()
        ft = "linux"
        spec = build_apps.CEYX_FETCH_SPECS[ft]
        with tempfile.TemporaryDirectory() as td:
            decoder_dir = Path(td)
            dest_dir = decoder_dir / spec["dest"]
            dest_dir.mkdir(parents=True)
            member = spec["members"][0]
            (dest_dir / member["artifact"]).write_bytes(b"whatever bytes are on disk")

            def fake_load_ceyx_pin_no_digest_for_member():
                return (
                    "v0.0.0-test",
                    {
                        ft: {
                            "libraries": [
                                # "artifact" present but "sha256" missing --
                                # digest_by_artifact filters this entry out.
                                {"member": member["member"],
                                 "artifact": member["artifact"]},
                            ],
                        },
                    },
                    {"asset": "artifacts.lock", "sha256": "ignored"},
                )

            orig = build_apps.load_ceyx_pin
            build_apps.load_ceyx_pin = fake_load_ceyx_pin_no_digest_for_member
            try:
                due = build_apps.ceyx_fetch_is_due(
                    ft, self._make_layout(decoder_dir), self._make_args())
            finally:
                build_apps.load_ceyx_pin = orig
            self.assertFalse(
                due,
                "a member missing a pinned digest must skip its "
                "checksum-mismatch check, not force a refetch")

    def test_check_pin_other_arch_when_sibling_group_matches(self):
        """S-A4 fix (2026-09-12): two fetch-targets sharing ONE on-disk path
        (like macos-arm64/macos-x86_64) must not both report PIN-MISMATCH
        when the on-disk bytes are legitimately one of the two pinned groups.
        The non-matching group's row is OTHER-ARCH (visible, not counted),
        the matching group's row is PIN-OK, and the preflight is CLEAN
        (return False / no genuine mismatch)."""
        import contextlib  # noqa: PLC0415
        import hashlib  # noqa: PLC0415
        import io  # noqa: PLC0415
        import tempfile  # noqa: PLC0415

        build_apps = _build_apps_module()
        with tempfile.TemporaryDirectory() as td:
            decoder_dir = Path(td)
            dest = Path("shared") / "Libraries"
            dest_dir = decoder_dir / dest
            dest_dir.mkdir(parents=True)
            artifact = "shared_decoder.dylib"
            on_disk_bytes = b"group-a's pinned bytes"
            (dest_dir / artifact).write_bytes(on_disk_bytes)
            digest_a = hashlib.sha256(on_disk_bytes).hexdigest()
            digest_b = hashlib.sha256(b"group-b's DIFFERENT pinned bytes").hexdigest()

            fake_specs = {
                "group-a": {"dest": dest, "members": [{"member": artifact, "artifact": artifact}]},
                "group-b": {"dest": dest, "members": [{"member": artifact, "artifact": artifact}]},
            }

            def fake_load_ceyx_pin():
                return (
                    "v0.0.0-test",
                    {
                        "group-a": {"libraries": [
                            {"member": artifact, "artifact": artifact, "sha256": digest_a}]},
                        "group-b": {"libraries": [
                            {"member": artifact, "artifact": artifact, "sha256": digest_b}]},
                    },
                    {"asset": "artifacts.lock", "sha256": "ignored"},
                )

            orig_specs = build_apps.CEYX_FETCH_SPECS
            orig_pin = build_apps.load_ceyx_pin
            build_apps.CEYX_FETCH_SPECS = fake_specs
            build_apps.load_ceyx_pin = fake_load_ceyx_pin
            try:
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf):
                    mismatched = build_apps.ceyx_check_pin(self._make_layout(decoder_dir))
            finally:
                build_apps.CEYX_FETCH_SPECS = orig_specs
                build_apps.load_ceyx_pin = orig_pin

            output = buf.getvalue()
            self.assertFalse(mismatched, "a same-path sibling match must not count as a mismatch")
            self.assertIn("PIN-OK group-a/shared_decoder.dylib", output)
            self.assertIn("OTHER-ARCH group-b/shared_decoder.dylib", output)
            self.assertNotIn("PIN-MISMATCH", output)
            self.assertIn("PIN-SUMMARY checked=2 mismatched=0 absent=0 uncovered=0 other_arch=1",
                          output)

    def test_check_pin_genuine_mismatch_not_reclassified(self):
        """A stale artifact matching NO sibling group's pin at all must stay
        a genuine PIN-MISMATCH, not be swallowed by the OTHER-ARCH path."""
        import contextlib  # noqa: PLC0415
        import hashlib  # noqa: PLC0415
        import io  # noqa: PLC0415
        import tempfile  # noqa: PLC0415

        build_apps = _build_apps_module()
        with tempfile.TemporaryDirectory() as td:
            decoder_dir = Path(td)
            dest = Path("shared") / "Libraries"
            dest_dir = decoder_dir / dest
            dest_dir.mkdir(parents=True)
            artifact = "shared_decoder.dylib"
            (dest_dir / artifact).write_bytes(b"corrupted, matches neither pin")
            digest_a = hashlib.sha256(b"group-a's pinned bytes").hexdigest()
            digest_b = hashlib.sha256(b"group-b's DIFFERENT pinned bytes").hexdigest()

            fake_specs = {
                "group-a": {"dest": dest, "members": [{"member": artifact, "artifact": artifact}]},
                "group-b": {"dest": dest, "members": [{"member": artifact, "artifact": artifact}]},
            }

            def fake_load_ceyx_pin():
                return (
                    "v0.0.0-test",
                    {
                        "group-a": {"libraries": [
                            {"member": artifact, "artifact": artifact, "sha256": digest_a}]},
                        "group-b": {"libraries": [
                            {"member": artifact, "artifact": artifact, "sha256": digest_b}]},
                    },
                    {"asset": "artifacts.lock", "sha256": "ignored"},
                )

            orig_specs = build_apps.CEYX_FETCH_SPECS
            orig_pin = build_apps.load_ceyx_pin
            build_apps.CEYX_FETCH_SPECS = fake_specs
            build_apps.load_ceyx_pin = fake_load_ceyx_pin
            try:
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf):
                    mismatched = build_apps.ceyx_check_pin(self._make_layout(decoder_dir))
            finally:
                build_apps.CEYX_FETCH_SPECS = orig_specs
                build_apps.load_ceyx_pin = orig_pin

            output = buf.getvalue()
            self.assertTrue(mismatched, "bytes matching neither pinned group is a genuine mismatch")
            self.assertIn("PIN-MISMATCH group-a/shared_decoder.dylib", output)
            self.assertIn("PIN-MISMATCH group-b/shared_decoder.dylib", output)
            self.assertNotIn("OTHER-ARCH", output)
            self.assertIn("PIN-SUMMARY checked=2 mismatched=2 absent=0 uncovered=0 other_arch=0",
                          output)


class TestWi15MemberSetEqual(unittest.TestCase):
    """WI-15 step 15.4 (S-H2): _member_set_equal is the literal
    "archive members == pin members" comparison, factored out of
    update_ceyx_pin_latest so it is testable without a network download --
    extract_ceyx_archive's own guards make the real CLI path structurally
    unable to reach a False here (they fail() one step earlier on any real
    mismatch), so this unit test is where the red/green proof for S-H2
    actually lives."""

    def test_green_equal_sets(self):
        build_apps = _build_apps_module()
        self.assertTrue(
            build_apps._member_set_equal(
                ["heif.dll", "libde265.dll"], ["libde265.dll", "heif.dll"]
            ),
            "same members in different order must compare equal (set, not "
            "list, comparison)",
        )

    def test_red_archive_missing_a_pin_member(self):
        build_apps = _build_apps_module()
        self.assertFalse(
            build_apps._member_set_equal(
                ["dng_decoder_native.dll", "heif.dll", "libde265.dll"],
                ["dng_decoder_native.dll", "heif.dll"],
            ),
            "an archive missing a member the pin names must not compare equal",
        )

    def test_red_archive_has_an_extra_member(self):
        build_apps = _build_apps_module()
        self.assertFalse(
            build_apps._member_set_equal(
                ["libdng_decoder_native.so"],
                ["libdng_decoder_native.so", "libcanary.so"],
            ),
            "an archive carrying a member the pin does not name must not "
            "compare equal",
        )


class TestWi15PlacedField(unittest.TestCase):
    """WI-15 step 15.5 (S-H3): every asset in the committed pin has an
    explicit 'placed' bool, and 'not_placed_reason' is present (non-empty)
    iff placed is False."""

    def test_every_asset_has_placed_and_consistent_reason(self):
        import json  # noqa: PLC0415

        data = json.loads(PIN_FILE.read_text(encoding="utf-8"))
        for name, entry in data["assets"].items():
            with self.subTest(asset=name):
                self.assertIn("placed", entry, f"{name} has no 'placed' field")
                self.assertIsInstance(entry["placed"], bool)
                reason = entry.get("not_placed_reason")
                if entry["placed"]:
                    self.assertFalse(
                        reason,
                        f"{name}: placed=true but not_placed_reason={reason!r}",
                    )
                else:
                    self.assertTrue(
                        reason and isinstance(reason, str),
                        f"{name}: placed=false needs a non-empty "
                        f"not_placed_reason, got {reason!r}",
                    )

    def test_load_ceyx_pin_rejects_missing_placed(self):
        build_apps = _build_apps_module()

        import json  # noqa: PLC0415

        data = json.loads(PIN_FILE.read_text(encoding="utf-8"))
        del data["assets"]["linux"]["placed"]
        orig_path = build_apps.CEYX_PIN_PATH
        import tempfile  # noqa: PLC0415

        with tempfile.TemporaryDirectory() as td:
            broken = Path(td) / "ceyx_release_pin.json"
            broken.write_text(json.dumps(data), encoding="utf-8")
            build_apps.CEYX_PIN_PATH = broken
            try:
                with self.assertRaises(SystemExit):
                    build_apps.load_ceyx_pin()
            finally:
                build_apps.CEYX_PIN_PATH = orig_path

    def test_load_ceyx_pin_rejects_placed_false_without_reason(self):
        build_apps = _build_apps_module()

        import json  # noqa: PLC0415

        data = json.loads(PIN_FILE.read_text(encoding="utf-8"))
        data["assets"]["android"]["not_placed_reason"] = ""
        orig_path = build_apps.CEYX_PIN_PATH
        import tempfile  # noqa: PLC0415

        with tempfile.TemporaryDirectory() as td:
            broken = Path(td) / "ceyx_release_pin.json"
            broken.write_text(json.dumps(data), encoding="utf-8")
            build_apps.CEYX_PIN_PATH = broken
            try:
                with self.assertRaises(SystemExit):
                    build_apps.load_ceyx_pin()
            finally:
                build_apps.CEYX_PIN_PATH = orig_path


class TestCeyxFetchSpecsMatchPin(unittest.TestCase):
    """build_apps.CEYX_FETCH_SPECS and scripts/ceyx_release_pin.json describe the
    same assets: same keys, archive names, placed flag/reason, member and
    artifact sets (the 2026-09-05 Android 3-file and 2026-09-13 webp/jxl drift
    class, caught at selftest instead of fetch time). `dest` and
    `atomic_group` are code-only facts the pin does not carry - not compared.
    Read-only on the pin (G-6)."""

    def _pin_and_specs(self):
        import json  # noqa: PLC0415

        pin = json.loads(PIN_FILE.read_text(encoding="utf-8"))
        return pin["assets"], _build_apps_module().CEYX_FETCH_SPECS

    def test_asset_keys_equal(self):
        assets, specs = self._pin_and_specs()
        self.assertEqual(sorted(assets), sorted(specs))

    def test_shared_fields_equal_per_asset(self):
        assets, specs = self._pin_and_specs()
        for key, spec in specs.items():
            entry = assets.get(key)
            if entry is None:
                continue  # reported by test_asset_keys_equal
            with self.subTest(asset=key):
                self.assertEqual(entry["archive"], spec["archive"])
                placed = entry.get("placed")  # load_ceyx_pin: absent/null = placed
                self.assertEqual(True if placed is None else placed, spec["place"])
                self.assertEqual(entry.get("not_placed_reason"), spec.get("not_placed_reason"))
                for field in ("member", "artifact"):
                    self.assertEqual(
                        sorted(lib[field] for lib in entry["libraries"]),
                        sorted(m[field] for m in spec["members"]),
                        field,
                    )


if __name__ == "__main__":
    unittest.main()
