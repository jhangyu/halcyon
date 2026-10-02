"""Artefact sources for the R-7 assertion suite: the packaged archive if there
is one, else the build tree. One surface (members / read / find /
materialise / executable_members) over zip, tar.gz and a directory."""

from __future__ import annotations

import os
import tarfile
import zipfile
from pathlib import Path

from . import targets


class _Source:
    """Common surface: member names, member bytes, and a real on-disk path."""

    def __init__(self, kind, location):
        self.kind = kind
        self.location = location

    def describe(self):
        return f"{self.kind} {self.location}"

    def members(self):
        raise NotImplementedError

    def read(self, name):
        raise NotImplementedError

    def materialise(self, workdir):
        """Return a directory on disk holding the artefact's contents."""
        raise NotImplementedError

    def find(self, basenames):
        """Member names whose basename is in `basenames` (files only)."""
        wanted = set(basenames)
        return [n for n in self.members() if n.rsplit("/", 1)[-1] in wanted]

    def executable_members(self):
        """Member names carrying an executable permission bit.

        Only used to make an H-ARCH failure diagnosable: "expected X, found
        [...]" tells a reader whether the runner was renamed or simply absent,
        instead of leaving them to unpack the artefact by hand.
        """
        raise NotImplementedError


class _TreeSource(_Source):
    def __init__(self, root, base):
        super().__init__("build-tree", os.fspath(root))
        self._root = Path(root)
        self._base = Path(base)

    def members(self):
        names = []
        for path in sorted(self._root.rglob("*")):
            if path.is_file() and not path.is_symlink():
                names.append(path.relative_to(self._base).as_posix())
        return names

    def _path(self, name):
        return self._base / name

    def read(self, name):
        return self._path(name).read_bytes()

    def materialise(self, workdir):
        return self._base

    def executable_members(self):
        return [n for n in self.members() if os.access(self._path(n), os.X_OK)]


class _ZipSource(_Source):
    def __init__(self, archive):
        super().__init__("archive", os.fspath(archive))
        self._archive = Path(archive)

    def members(self):
        with zipfile.ZipFile(self._archive) as zf:
            return [i.filename for i in zf.infolist() if not i.is_dir()]

    def read(self, name):
        with zipfile.ZipFile(self._archive) as zf:
            return zf.read(name)

    def materialise(self, workdir):
        with zipfile.ZipFile(self._archive) as zf:
            zf.extractall(workdir)
        return Path(workdir)

    def executable_members(self):
        with zipfile.ZipFile(self._archive) as zf:
            return [
                i.filename
                for i in zf.infolist()
                if not i.is_dir() and (i.external_attr >> 16) & 0o111
            ]


class _TarSource(_Source):
    def __init__(self, archive):
        super().__init__("archive", os.fspath(archive))
        self._archive = Path(archive)

    def members(self):
        with tarfile.open(self._archive, "r:gz") as tf:
            return [m.name for m in tf.getmembers() if m.isfile()]

    def read(self, name):
        with tarfile.open(self._archive, "r:gz") as tf:
            extracted = tf.extractfile(name)
            if extracted is None:
                raise KeyError(name)
            return extracted.read()

    def materialise(self, workdir):
        with tarfile.open(self._archive, "r:gz") as tf:
            tf.extractall(workdir)
        return Path(workdir)

    def executable_members(self):
        with tarfile.open(self._archive, "r:gz") as tf:
            return [m.name for m in tf.getmembers() if m.isfile() and m.mode & 0o111]


def _archive_candidates(repo_root, spec):
    pattern = spec["archive_name"].format(version="*")
    return sorted(
        (p for p in Path(repo_root).glob(pattern) if p.is_file()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )


def resolve_source(repo_root, target, archive=None):
    """Pick the artefact to measure: an explicit archive, else the newest
    matching archive in the repo root, else the build tree.

    Returns (source, None) or (None, error_message).
    """
    repo_root = Path(repo_root)
    spec = targets.spec(target)

    chosen = Path(archive) if archive else None
    if chosen is None:
        candidates = _archive_candidates(repo_root, spec)
        chosen = candidates[0] if candidates else None

    if chosen is not None:
        if not chosen.is_file():
            return None, f"ERROR: archive not found at {chosen}"
        if spec["archive_format"] == "gztar":
            return _TarSource(chosen), None
        return _ZipSource(chosen), None

    raw = spec["artifact_path"]
    if spec["artifact_kind"] == "glob_dir":
        matches = sorted(repo_root.glob(raw))
        if not matches:
            return None, (
                f"ERROR: no artifact matched {raw} and no archive matched "
                f"{spec['archive_name'].format(version='*')}"
            )
        root = matches[0]
    else:
        root = repo_root / raw
        if not root.is_dir():
            return None, (
                f"ERROR: no artifact at {root} and no archive matched "
                f"{spec['archive_name'].format(version='*')}"
            )
    # Member names mirror what package() writes into the archive: an app bundle
    # keeps its own directory as the prefix (ditto --keepParent), a plain dir is
    # archived from inside, and a linux bundle is archived as "bundle/".
    base = root.parent if spec["artifact_kind"] in ("app_bundle", "glob_dir") else root
    return _TreeSource(root, base), None
