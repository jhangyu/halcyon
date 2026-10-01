"""Characterization tests for the artefact-source adapters (_TreeSource,
_ZipSource, _TarSource, _archive_candidates, resolve_source) over tempfile
fixtures. resolve_source reads the real targets.py data; only repo_root is
synthetic."""

from __future__ import annotations

import io
import os
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))

from ci import sources  # noqa: E402

_FILES = {"top.txt": b"top", "lib/nested.dll": b"nested", "bin/runner": b"exe"}


def _write_zip(path):
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr(zipfile.ZipInfo("lib/"), b"")  # directory entry: never a member
        for name, data in _FILES.items():
            info = zipfile.ZipInfo(name)
            info.external_attr = (0o755 if name == "bin/runner" else 0o644) << 16
            zf.writestr(info, data)


def _write_tar(path):
    with tarfile.open(path, "w:gz") as tf:
        for name, data in _FILES.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o755 if name == "bin/runner" else 0o644
            tf.addfile(info, io.BytesIO(data))


def _write_tree(root):
    for name, data in _FILES.items():
        path = Path(root, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        os.chmod(path, 0o755 if name == "bin/runner" else 0o644)


class _SourceContract:
    """Shared expectations for every adapter; subclasses build `self.source`."""

    def test_members_are_files_only(self):
        self.assertEqual(sorted(self.source.members()), sorted(_FILES))

    def test_read_round_trips_bytes(self):
        for name, data in _FILES.items():
            self.assertEqual(self.source.read(name), data)

    def test_find_matches_basename_not_path(self):
        self.assertEqual(self.source.find(["nested.dll"]), ["lib/nested.dll"])
        self.assertEqual(self.source.find(["lib"]), [])

    def test_executable_members(self):
        self.assertEqual(self.source.executable_members(), ["bin/runner"])

    def test_materialise_holds_the_files(self):
        root = Path(self.source.materialise(self.workdir))
        self.assertEqual((root / "lib/nested.dll").read_bytes(), b"nested")


class TreeSourceTests(_SourceContract, unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        _write_tree(tmp.name)
        self.workdir = tmp.name
        self.source = sources._TreeSource(tmp.name, tmp.name)

    def test_describe(self):
        self.assertEqual(self.source.describe(), f"build-tree {self.workdir}")

    @unittest.skipIf(os.name == "nt", "os.access(X_OK) reports every existing file executable on Windows")
    def test_executable_members(self):
        super().test_executable_members()


class ZipSourceTests(_SourceContract, unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        archive = Path(tmp.name, "a.zip")
        _write_zip(archive)
        self.workdir = Path(tmp.name, "out")
        self.workdir.mkdir()
        self.source = sources._ZipSource(archive)


class TarSourceTests(_SourceContract, unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        archive = Path(tmp.name, "a.tar.gz")
        _write_tar(archive)
        self.workdir = Path(tmp.name, "out")
        self.workdir.mkdir()
        self.source = sources._TarSource(archive)

    def test_read_missing_member_raises_keyerror(self):
        with self.assertRaises(KeyError):
            self.source.read("absent.txt")


class ResolveSourceTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def test_explicit_missing_archive_is_an_error(self):
        source, error = sources.resolve_source(self.root, "macos", archive=self.root / "no.zip")
        self.assertIsNone(source)
        self.assertIn("archive not found", error)

    def test_gztar_target_gets_a_tar_source(self):
        archive = self.root / "x.tar.gz"
        _write_tar(archive)
        source, error = sources.resolve_source(self.root, "linux", archive=archive)
        self.assertIsNone(error)
        self.assertIsInstance(source, sources._TarSource)

    def test_newest_matching_archive_wins_over_build_tree(self):
        old = self.root / "Halcyon-windows-x64-1.0.0.zip"
        new = self.root / "Halcyon-windows-x64-1.0.1.zip"
        _write_zip(old)
        _write_zip(new)
        os.utime(old, (1_000_000, 1_000_000))
        os.utime(new, (2_000_000, 2_000_000))
        _write_tree(self.root / "build/windows/x64/runner/Release")
        spec = sources.targets.spec("windows")
        self.assertEqual(sources._archive_candidates(self.root, spec), [new, old])
        source, _ = sources.resolve_source(self.root, "windows")
        self.assertIsInstance(source, sources._ZipSource)
        self.assertEqual(source.location, os.fspath(new))

    def test_dir_target_falls_back_to_tree_rooted_at_the_dir(self):
        _write_tree(self.root / "build/windows/x64/runner/Release")
        source, error = sources.resolve_source(self.root, "windows")
        self.assertIsNone(error)
        self.assertIsInstance(source, sources._TreeSource)
        self.assertIn("lib/nested.dll", source.members())

    def test_app_bundle_members_keep_the_bundle_prefix(self):
        _write_tree(self.root / "build/macos/Build/Products/Release/Halcyon.app")
        source, _ = sources.resolve_source(self.root, "macos")
        self.assertIn("Halcyon.app/lib/nested.dll", source.members())

    def test_glob_dir_target_resolves_the_glob(self):
        _write_tree(self.root / "build/linux/x64/release/bundle")
        source, _ = sources.resolve_source(self.root, "linux")
        self.assertIn("bundle/lib/nested.dll", source.members())

    def test_no_archive_and_no_tree_is_an_error(self):
        for target in ("windows", "linux"):
            with self.subTest(target=target):
                source, error = sources.resolve_source(self.root, target)
                self.assertIsNone(source)
                self.assertTrue(error.startswith("ERROR: no artifact"), error)


if __name__ == "__main__":
    unittest.main()
