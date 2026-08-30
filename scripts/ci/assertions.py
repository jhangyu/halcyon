"""R-7 capability assertions: does the artefact we are about to ship actually
have the capability, or do we merely have a platform proxy that agrees with it?

Frozen interface: Plan_ci_rewrite.md §2 / §WP-C, Spec_ci_rewrite.md §4.5.

Design rules this module exists to enforce (ceyx burned four rounds learning
them, 2026-08-30):

  * Every assertion states what it MEASURES, on which platforms that instrument
    is VALID, WHY it is valid there, the RED STATE that makes it fail, and the
    EXPECTED green result. ``validate_suite()`` refuses a record missing any of
    the five, and ``run_suite()`` calls it first, so an under-specified
    assertion can never run.
  * The instrument must test the capability, not a proxy for it. The
    sized-symbol assertion is a functional FFI probe (``DynamicLibrary.open`` +
    ``lookup``) because that is the question the loader answers at runtime on
    every platform. The ``nm``/``dumpbin`` symbol-table instrument is kept only
    as the secondary record ``H-SIZED-SYMBOL-NM``, and is NOT ``valid_on``
    windows: PE exports nothing by default, so on Windows the symbol table
    measures a build-system setting rather than reachability (OQ-1 ruling c,
    PL-9).
  * A silently skipped gate produces a green report indistinguishable from a
    full run (2026-08-25). So: a skip for an artefact on its OWN platform is a
    FAILURE, every legitimate skip prints exactly one ``SKIP:`` line, and the
    summary states the skipped count.
  * G-3: no ``| grep`` in any argv. Tool output is captured to ``str`` and
    matched in Python.
  * G-6: ``ceyx_release_pin.json`` and ``dng_ffi_artifacts.json`` are read as
    DATA and never written. The Windows DLL list is never hardcoded here.

Artefact source. The assertions run against the packaged archive when one
exists — that is the difference between "we built the right bytes" and "we
shipped the right bytes". When no archive exists yet (``ci.yml``'s build job
runs ``assert-capabilities`` before any packaging), the built artefact tree is
used instead and the source is named in every line of output, so a reader can
always tell which of the two was measured.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import struct
import sys
import tarfile
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path

from . import report, targets
from .run import run

SYMBOL = "dng_decode_and_process_sized"

# Host detection is a dict lookup, not a branch (G-5). It is used ONLY for skip
# semantics — "is this artefact running on its own platform?" — never to choose
# what to build or where to look.
_HOST_BY_SYS_PLATFORM = {"darwin": "macos", "linux": "linux", "win32": "windows"}

# Names the Flutter runner executable can have inside a packaged artefact.
_APP_EXECUTABLE_NAMES = ("Halcyon", "Halcyon.exe")


@dataclass(frozen=True)
class Assertion:
    id: str
    measures: str
    valid_on: tuple
    why_valid: str
    red_state: str
    expected: str


SUITE = {
    "H-ARCH": Assertion(
        id="H-ARCH",
        measures=(
            "the machine architecture of the app executable inside the shipped "
            "artefact equals the architecture declared for that target"
        ),
        valid_on=("macos", "linux", "windows"),
        why_valid=(
            "The architecture is read structurally from the file's own header "
            "(Mach-O cputype / ELF e_machine / PE IMAGE_FILE_HEADER.Machine) in "
            "pure Python, so no external tool, no host toolchain and no shell "
            "pipeline can invert the answer (G-3). The three headers are "
            "format-defined constants, which is why one instrument is valid on "
            "all three platforms."
        ),
        red_state=(
            "point the assertion at a binary of a different architecture (e.g. "
            "an x86_64 executable for the macos target): it fails naming both "
            "the expected and the observed arch"
        ),
        expected="observed arch == the target's expected_arch in dng_ffi_artifacts.json",
    ),
    "H-DECODER-PRESENT": Assertion(
        id="H-DECODER-PRESENT",
        measures=(
            "the ceyx decoder library is present INSIDE the shipped artefact, "
            "at a path the app can DynamicLibrary.open"
        ),
        valid_on=("macos", "linux", "windows"),
        why_valid=(
            "The inventory is read from the archive itself (zipfile/tarfile), "
            "not from the build tree, so it catches the packaging step dropping "
            "a library that the build produced correctly. Library presence is "
            "a necessary condition for DynamicLibrary.open on every platform."
        ),
        red_state=(
            "remove the decoder library from a staging copy before packaging: "
            "the assertion fails naming the missing basename"
        ),
        expected="a member whose basename == the target's decoder_artifact exists",
    ),
    "H-DECODER-DEPS": Assertion(
        id="H-DECODER-DEPS",
        measures=(
            "every ceyx library the pin declares for this platform is in the "
            "artefact TOGETHER (on Windows: the decoder plus heif.dll and "
            "libde265.dll)"
        ),
        valid_on=("windows",),
        why_valid=(
            "The expected list is read as data from ceyx_release_pin.json's "
            "assets.<platform>.libraries — never hardcoded (R-1a/R-1c) — so "
            "adding a fourth DLL to the pin automatically extends the gate. It "
            "measures the exact failure ceyx_release_pin.json:11-16 describes: "
            "a Windows install missing a dynamic import fails at "
            "DynamicLibrary.open with an error naming only the decoder."
        ),
        red_state=(
            "delete heif.dll from a staging copy of the archive: the assertion "
            "fails naming heif.dll"
        ),
        expected="all pinned library artifact names present in the artefact",
    ),
    "H-DECODER-HASH": Assertion(
        id="H-DECODER-HASH",
        measures=(
            "the SHA-256 of each ceyx library AS SHIPPED equals the pinned digest"
        ),
        valid_on=("linux", "windows"),
        why_valid=(
            "hashlib over the artefact member's own bytes. build_apps.py "
            "verifies the digest at FETCH time; hashing the shipped member "
            "instead is what distinguishes 'we downloaded the right bytes' from "
            "'we shipped the right bytes' — the two differ whenever anything "
            "between fetch and package rewrites the file. macOS is excluded "
            "because it is intentionally absent from the pin (its six dylibs "
            "are committed and install-name/codesign wired)."
        ),
        red_state=(
            "flip one byte of a library in a staging copy: the assertion fails "
            "printing the expected and observed digests"
        ),
        expected="sha256(member) == pin digest for every pinned library",
    ),
    "H-SIZED-SYMBOL": Assertion(
        id="H-SIZED-SYMBOL",
        measures=(
            f"{SYMBOL} is REACHABLE at runtime in the shipped decoder — the "
            "loader resolves it, not merely a symbol table listing it"
        ),
        valid_on=("macos", "linux", "windows"),
        why_valid=(
            "scripts/ci/probe/ffi_probe.dart performs DynamicLibrary.open + "
            "lookup, i.e. it asks the platform loader the same question the app "
            "asks. This is capability, not proxy, and it is format-agnostic — "
            "which is exactly why it, and not nm/dumpbin, is valid on Windows "
            "(OQ-1 ruling c). It can only run where the library is loadable, so "
            "it applies on the artefact's own platform; on a foreign host it "
            "reports a SKIP with that reason rather than a false pass."
        ),
        red_state=(
            "point the probe at a nonexistent path or a library built without "
            "the symbol: PROBE-FAIL on stderr and exit 1 (demonstrated: "
            "docs/logs/2026-08-31/red-state-H-SIZED-SYMBOL.txt)"
        ),
        expected="probe exits 0 printing PROBE-OK",
    ),
    "H-SIZED-SYMBOL-NM": Assertion(
        id="H-SIZED-SYMBOL-NM",
        measures=(
            f"{SYMBOL} appears in the decoder's dynamic symbol table "
            "(secondary cross-check of H-SIZED-SYMBOL)"
        ),
        valid_on=("macos", "linux"),
        why_valid=(
            "On Mach-O and ELF, default symbol visibility is permissive: a "
            "symbol listed by nm really is resolvable by dlsym, so the table "
            "agrees with the runtime. WINDOWS IS DELIBERATELY EXCLUDED from "
            "valid_on: PE exports nothing unless the build declares it, so "
            "dumpbin /exports measures a build-system setting, not runtime "
            "reachability — ceyx spent two rounds forcing a healthy artefact to "
            "satisfy that instrument (2026-08-30). Windows may only be "
            "re-included after its red state is demonstrated on a real Windows "
            "runner (PL-9). nm's output is captured to a str and matched in "
            "Python, never piped to grep (G-3: `nm | grep -q` returns 141 under "
            "pipefail when the symbol IS found)."
        ),
        red_state=(
            "run against a library built without the symbol, or strip it: nm's "
            "captured output does not contain the symbol and the assertion fails"
        ),
        expected=f"'{SYMBOL}' occurs in the captured nm output",
    ),
}

_MANDATORY_FIELDS = ("measures", "valid_on", "why_valid", "red_state", "expected")


def validate_suite():
    """Raise ValueError naming any assertion missing a mandatory field."""
    for key, record in SUITE.items():
        if record.id != key:
            raise ValueError(f"assertion {key!r}: id field is {record.id!r}")
        for field_name in _MANDATORY_FIELDS:
            value = getattr(record, field_name, None)
            if value is None or (hasattr(value, "__len__") and len(value) == 0):
                raise ValueError(
                    f"assertion {key!r} is missing mandatory field {field_name!r}; "
                    "an assertion that does not state what it measures, where it "
                    "is valid, why, its red state and its expected result may "
                    "not run (Spec §4.5)"
                )


# --------------------------------------------------------------------------
# Data loading (read-only; G-6)
# --------------------------------------------------------------------------


def _load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def ffi_entry_for(repo_root, target):
    """The dng_ffi_artifacts.json platform entry whose ci_target is `target`.

    Returns None when no entry claims this target (web, android-apk).
    """
    manifest = _load_json(Path(repo_root) / "scripts" / "dng_ffi_artifacts.json")
    for entry in manifest["platforms"].values():
        if entry.get("ci_target") == target:
            return entry
    return None


def platform_of(repo_root, target):
    """The artefact platform name (macos/windows/linux/android) for a CI target.

    The mapping lives in dng_ffi_artifacts.json as the ``ci_target`` field, so
    it is data, not a branch. Falls back to the target name itself.
    """
    manifest = _load_json(Path(repo_root) / "scripts" / "dng_ffi_artifacts.json")
    for name, entry in manifest["platforms"].items():
        if entry.get("ci_target") == target:
            return name
    return target


def pinned_libraries(repo_root, pin_platform):
    """The pin's library records for a platform, as data. [] when unpinned."""
    if not pin_platform:
        return []
    pin = _load_json(Path(repo_root) / "scripts" / "ceyx_release_pin.json")
    return pin["assets"][pin_platform]["libraries"]


# --------------------------------------------------------------------------
# Architecture, read structurally from the file's own header
# --------------------------------------------------------------------------

_MACHO_CPU = {0x0100000C: "arm64", 0x01000007: "x86_64", 0x00000007: "i386"}
_ELF_MACHINE = {0x3E: "x86_64", 0xB7: "aarch64", 0x28: "arm", 0x03: "i386"}
_PE_MACHINE = {0x8664: "x86_64", 0xAA64: "arm64", 0x14C: "i386"}


def machine_arch(data):
    """Return the architecture name encoded in a Mach-O/ELF/PE header.

    Raises ValueError when the bytes are not a recognised executable format.
    """
    if len(data) < 64:
        raise ValueError("file too short to carry an executable header")
    magic = data[:4]
    if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):  # Mach-O 64/32 LE
        cputype = struct.unpack_from("<I", data, 4)[0]
        return _MACHO_CPU.get(cputype, f"macho-cputype-0x{cputype:x}")
    if magic == b"\xca\xfe\xba\xbe":  # universal binary
        count = struct.unpack_from(">I", data, 4)[0]
        slices = []
        for index in range(count):
            cputype = struct.unpack_from(">I", data, 8 + index * 20)[0]
            slices.append(_MACHO_CPU.get(cputype, f"0x{cputype:x}"))
        return "+".join(slices)
    if magic == b"\x7fELF":
        endian = "<" if data[5] == 1 else ">"
        machine = struct.unpack_from(endian + "H", data, 18)[0]
        return _ELF_MACHINE.get(machine, f"elf-machine-0x{machine:x}")
    if magic[:2] == b"MZ":
        pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
        if data[pe_offset : pe_offset + 4] != b"PE\x00\x00":
            raise ValueError("MZ header without a PE signature")
        machine = struct.unpack_from("<H", data, pe_offset + 4)[0]
        return _PE_MACHINE.get(machine, f"pe-machine-0x{machine:x}")
    raise ValueError(f"unrecognised executable format (magic {magic!r})")


# --------------------------------------------------------------------------
# Artefact sources: the packaged archive if there is one, else the build tree
# --------------------------------------------------------------------------


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


# --------------------------------------------------------------------------
# Assertion implementations. Each returns (status, message) with status in
# {"pass", "fail", "skip"}.
# --------------------------------------------------------------------------


def _assert_arch(ctx):
    entry = ctx["ffi_entry"]
    if entry is None:
        return "skip", "no dng_ffi_artifacts.json entry declares this ci_target"
    expected = entry["expected_arch"]
    hits = ctx["source"].find(_APP_EXECUTABLE_NAMES)
    if not hits:
        return "fail", (
            f"no app executable named {' or '.join(_APP_EXECUTABLE_NAMES)} found "
            f"in {ctx['source'].describe()}"
        )
    observed = []
    for name in hits:
        try:
            arch = machine_arch(ctx["source"].read(name))
        except ValueError as exc:
            return "fail", f"{name}: {exc}"
        observed.append((name, arch))
        if arch != expected:
            return "fail", f"{name}: expected arch {expected}, observed {arch}"
    detail = ", ".join(f"{n}={a}" for n, a in observed)
    return "pass", f"expected {expected}; {detail}"


def _assert_decoder_present(ctx):
    entry = ctx["ffi_entry"]
    if entry is None:
        return "skip", "no dng_ffi_artifacts.json entry declares this ci_target"
    basename = entry["decoder_artifact"]
    hits = ctx["source"].find([basename])
    if not hits:
        return "fail", (
            f"{basename} is absent from {ctx['source'].describe()} — the app "
            "would fail at DynamicLibrary.open"
        )
    return "pass", f"{basename} at {hits[0]}"


def _assert_decoder_deps(ctx):
    libraries = ctx["pin_libraries"]
    if not libraries:
        return "skip", "this target has no pin_platform, so the pin declares no libraries"
    missing = []
    found = []
    for library in libraries:
        name = library["artifact"]
        hits = ctx["source"].find([name])
        (found if hits else missing).append(name)
    if missing:
        return "fail", (
            "pinned libraries missing from the artefact: "
            + ", ".join(sorted(missing))
            + f" (present: {', '.join(sorted(found)) or 'none'})"
        )
    return "pass", f"all pinned libraries present: {', '.join(found)}"


def _assert_decoder_hash(ctx):
    libraries = ctx["pin_libraries"]
    if not libraries:
        return "skip", "this target has no pin_platform, so there are no pinned digests"
    failures = []
    checked = []
    for library in libraries:
        name = library["artifact"]
        hits = ctx["source"].find([name])
        if not hits:
            failures.append(f"{name}: absent from the artefact")
            continue
        observed = hashlib.sha256(ctx["source"].read(hits[0])).hexdigest()
        if observed != library["sha256"]:
            failures.append(
                f"{name}: expected sha256 {library['sha256']}, observed {observed}"
            )
        else:
            checked.append(f"{name}={observed[:12]}…")
    if failures:
        return "fail", "; ".join(failures)
    return "pass", "pinned digests matched: " + ", ".join(checked)


def _decoder_disk_path(ctx):
    """Absolute on-disk path of the decoder library, extracting if needed.

    dlopen treats a relative path as a search name rather than a file path, so
    the probe is always handed an absolute path.
    """
    entry = ctx["ffi_entry"]
    if entry is None:
        return None, "no dng_ffi_artifacts.json entry declares this ci_target"
    basename = entry["decoder_artifact"]
    root = ctx["source"].materialise(ctx["workdir"])
    matches = sorted(Path(root).rglob(basename))
    if not matches:
        return None, f"{basename} not found under {root}"
    return matches[0].resolve(), None


def _assert_sized_symbol(ctx):
    if ctx["host"] != ctx["artefact_platform"]:
        return "skip", (
            f"a {ctx['artefact_platform']} library cannot be loaded on a "
            f"{ctx['host']} host; the functional probe runs on the artefact's "
            "own platform (cross-platform runs are covered by that platform's CI job)"
        )
    dart = shutil.which("dart")
    if dart is None:
        return "skip", "dart is not on PATH"
    path, error = _decoder_disk_path(ctx)
    if path is None:
        return "fail", error
    probe = Path(ctx["repo_root"]) / "scripts" / "ci" / "probe" / "ffi_probe.dart"
    result = run([dart, "run", os.fspath(probe.resolve()), os.fspath(path)])
    output = (result.stdout + result.stderr).strip().splitlines()
    tail = output[-1] if output else "(no output)"
    if result.returncode != 0:
        return "fail", f"probe exited {result.returncode}: {tail}"
    return "pass", tail


def _assert_sized_symbol_nm(ctx):
    entry = ctx["ffi_entry"]
    if entry is None:
        return "skip", "no dng_ffi_artifacts.json entry declares this ci_target"
    tool = entry.get("tool")
    if not tool or shutil.which(tool) is None:
        return "skip", f"symbol-table tool {tool!r} is not on PATH"
    path, error = _decoder_disk_path(ctx)
    if path is None:
        return "fail", error
    # The instrument is check_dng_ffi_artifacts.check_symbol itself, imported
    # rather than re-implemented, so this gate and the manual cross-platform
    # checker can never drift into two different instruments. It captures the
    # tool's output to a str and matches in Python — never `nm | grep -q`,
    # which returns 141 under pipefail when the symbol IS found (G-3).
    status = _check_symbol()(path, tool, entry.get("tool_args", []), SYMBOL)
    if status == "skipped":
        return "skip", f"{tool} resolved but could not inspect {path.name}"
    if status != "present":
        return "fail", f"{SYMBOL} absent from {tool} output for {path.name}"
    return "pass", f"{SYMBOL} listed by {tool} for {path.name}"


def _check_symbol():
    """Import scripts/check_dng_ffi_artifacts.py's check_symbol lazily.

    ``scripts/`` is not a package, so the import happens here rather than at
    module import time, keeping ``import ci.assertions`` free of side effects.
    """
    scripts_dir = os.fspath(Path(__file__).resolve().parent.parent)
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)
    from check_dng_ffi_artifacts import check_symbol

    return check_symbol


_IMPLEMENTATIONS = {
    "H-ARCH": _assert_arch,
    "H-DECODER-PRESENT": _assert_decoder_present,
    "H-DECODER-DEPS": _assert_decoder_deps,
    "H-DECODER-HASH": _assert_decoder_hash,
    "H-SIZED-SYMBOL": _assert_sized_symbol,
    "H-SIZED-SYMBOL-NM": _assert_sized_symbol_nm,
}


def host_platform():
    """This host's platform name, or None if it is not one of the three."""
    return _HOST_BY_SYS_PLATFORM.get(sys.platform)


def run_suite(repo_root, target, archive=None):
    """Run the assertions targets.spec(target) declares. Returns an exit code.

    A skip on the artefact's OWN platform is a FAILURE: the tool's absence is
    an environment defect, not a legitimate skip (Spec §4.5).
    """
    validate_suite()
    repo_root = Path(repo_root).resolve()
    spec = targets.spec(target)
    ids = list(spec["assertions"])

    print(f"ASSERT: target={target} assertions={len(ids)}")
    if not ids:
        print(f"ASSERT-SUMMARY: {target} assertions=0 failed=0 skipped=0")
        return 0

    source, error = resolve_source(repo_root, target, archive=archive)
    if source is None:
        print(error)
        print(f"ASSERT-SUMMARY: {target} assertions={len(ids)} failed={len(ids)} skipped=0")
        return 1
    print(f"ASSERT-SOURCE: {source.describe()}")

    ffi_entry = ffi_entry_for(repo_root, target)
    artefact_platform = platform_of(repo_root, target)

    failed = 0
    skipped = 0
    with tempfile.TemporaryDirectory(prefix="halcyon-assert-") as workdir:
        ctx = {
            "repo_root": repo_root,
            "target": target,
            "spec": spec,
            "source": source,
            "ffi_entry": ffi_entry,
            "pin_libraries": pinned_libraries(repo_root, spec["pin_platform"]),
            "workdir": workdir,
            "host": host_platform(),
            "artefact_platform": artefact_platform,
        }
        for assertion_id in ids:
            record = SUITE[assertion_id]
            if artefact_platform not in record.valid_on:
                skipped += 1
                print(
                    report.skip_line(
                        assertion_id,
                        f"not valid_on {artefact_platform} (valid_on: "
                        f"{', '.join(record.valid_on)})",
                    )
                )
                continue
            status, message = _IMPLEMENTATIONS[assertion_id](ctx)
            if status == "pass":
                print(f"ASSERT-OK: {assertion_id} — {message}")
            elif status == "skip":
                if artefact_platform == ctx["host"]:
                    failed += 1
                    print(
                        f"ASSERT-FAIL: {assertion_id} — skipped on its own "
                        f"platform, which is an environment defect, not a "
                        f"legitimate skip: {message}"
                    )
                else:
                    skipped += 1
                    print(report.skip_line(assertion_id, message))
            else:
                failed += 1
                print(f"ASSERT-FAIL: {assertion_id} — {message}")
                print(f"    red_state: {record.red_state}")

    print(
        f"ASSERT-SUMMARY: {target} assertions={len(ids)} failed={failed} "
        f"skipped={skipped}"
    )
    return 1 if failed else 0
