"""Per-target CI data. DATA ONLY.

Frozen interface: Plan_ci_rewrite.md §2. G-5: this is the ONLY file under
``scripts/ci/`` allowed to state a per-platform fact — everywhere else, platform
is a parameter and the difference is a dict lookup. No ``import subprocess``
here, and no behaviour: a reader must be able to audit every platform fact by
reading one screen of literals against the workflow files they were copied from.

Provenance of every value below (transcribed byte-for-byte, not re-derived):
  build_flags   ci.yml:125, release.yml:60/102/138
  provision     release.yml:137 (apt), ci.yml:121 / release.yml:57 (pod install)
  artifact_path build_apps.py:1730-1752 (flutter_artifact)
  archive_name  release.yml:66/105/144
  app_executable macos/Runner/Configs/AppInfo.xcconfig:8 (PRODUCT_NAME),
                 windows/CMakeLists.txt:7 and linux/CMakeLists.txt:7 (BINARY_NAME)

``app_executable`` is the basename of the Flutter runner binary inside the
shipped artefact, and it is NOT the same string on every platform: only macOS
is named after the product ("Halcyon"); Windows is lowercase ("halcyon.exe")
and Linux still carries the pre-rename project name
("photo_selector_flutter"). ``archive_name`` above names the *zip/tarball* and
is deliberately product-branded on all targets — the two must not be conflated.
"""

from __future__ import annotations

TARGETS: dict = {
    "macos": {
        "runs_on": "macos-14",
        # No --fetch-native: macOS keeps its six committed, install-name/codesign
        # wired dylibs and is excluded from the ceyx release pin (CLAUDE.md).
        "build_flags": [],
        # `flutter pub get` (cwd=<repo_root>) then `pod install` (cwd=<repo_root>/macos,
        # ci.yml:121-123). The pub get is NOT optional and NOT a duplicate of the
        # one `flutter build` does implicitly: macos/Podfile:12-17 raises unless
        # macos/Flutter/ephemeral/Flutter-Generated.xcconfig exists, and that
        # directory is gitignored (macos/.gitignore:2), so only pub get creates it.
        # The pre-rewrite workflow ran it immediately before pod install
        # (main:.github/workflows/ci.yml:117-121); the rewrite dropped it, which is
        # the 2026-08-31 round-1 macOS provision failure.
        "provision": [["flutter", "pub", "get"], ["pod", "install"]],
        "artifact_kind": "app_bundle",
        "artifact_path": "build/macos/Build/Products/Release/Halcyon.app",
        # macos/Runner/Configs/AppInfo.xcconfig:8 — PRODUCT_NAME = Halcyon;
        # the binary lives at Halcyon.app/Contents/MacOS/Halcyon.
        "app_executable": "Halcyon",
        "archive_name": "Halcyon-macos-arm64-{version}.zip",
        "archive_format": "zip",
        "assertions": [
            "H-ARCH",
            "H-DECODER-PRESENT",
            "H-SIZED-SYMBOL",
            "H-SIZED-SYMBOL-NM",
        ],
        "pin_platform": None,
    },
    "windows": {
        "runs_on": "windows-latest",
        # --fetch-native, not plain auto: ceyx still carries a committed
        # dng_decoder_native.dll (hand-built, no S4 colour-gate record). Auto-fetch
        # only fires when the destination is ABSENT, so without this flag Windows
        # would keep shipping that unvalidated binary. release.yml:96-101.
        "build_flags": ["--fetch-native"],
        "provision": [],
        "artifact_kind": "dir",
        "artifact_path": "build/windows/x64/runner/Release",
        # windows/CMakeLists.txt:7 — set(BINARY_NAME "halcyon"); LOWERCASE, and
        # the runner is emitted as <BINARY_NAME>.exe.
        "app_executable": "halcyon.exe",
        "archive_name": "Halcyon-windows-x64-{version}.zip",
        "archive_format": "zip",
        # H-SIZED-SYMBOL-NM is deliberately absent: the symbol-table instrument is
        # structurally invalid on PE (no default export visibility). PL-9.
        "assertions": [
            "H-ARCH",
            "H-DECODER-PRESENT",
            "H-DECODER-DEPS",
            "H-DECODER-HASH",
            "H-SIZED-SYMBOL",
        ],
        "pin_platform": "windows",
    },
    "linux": {
        "runs_on": "ubuntu-latest",
        "build_flags": [],
        "provision": [
            ["sudo", "apt-get", "update"],
            ["sudo", "apt-get", "install", "-y", "ninja-build", "libgtk-3-dev"],
        ],
        # The arch segment is host-dependent (build_apps.py:1748-1751), hence glob.
        "artifact_kind": "glob_dir",
        "artifact_path": "build/linux/*/release/bundle",
        # linux/CMakeLists.txt:7 — set(BINARY_NAME "photo_selector_flutter").
        # The Linux runner was never renamed to the product name; the bundle
        # ships bundle/photo_selector_flutter.
        "app_executable": "photo_selector_flutter",
        "archive_name": "Halcyon-linux-x64-{version}.tar.gz",
        "archive_format": "gztar",
        "assertions": [
            "H-ARCH",
            "H-DECODER-PRESENT",
            "H-DECODER-HASH",
            "H-SIZED-SYMBOL",
            "H-SIZED-SYMBOL-NM",
        ],
        "pin_platform": "linux",
    },
    "android-apk": {
        "runs_on": "ubuntu-latest",
        "build_flags": [],
        "provision": [],
        "artifact_kind": "dir",
        "artifact_path": "build/app/outputs/flutter-apk",
        # No host executable in an APK (the runner is a Dalvik app plus .so
        # payloads), and "assertions" below is empty so H-ARCH never runs here.
        "app_executable": None,
        "archive_name": "Halcyon-android-apk-{version}.zip",
        "archive_format": "zip",
        # Not a release target this round: no desktop decoder library ships here,
        # so no R-7 record applies. See Plan §6 / PL-5.
        "assertions": [],
        "pin_platform": None,
    },
    "web": {
        "runs_on": "ubuntu-latest",
        "build_flags": [],
        "provision": [],
        "artifact_kind": "dir",
        "artifact_path": "build/web",
        # A web bundle has no native executable at all; "assertions" is empty.
        "app_executable": None,
        "archive_name": "Halcyon-web-{version}.zip",
        "archive_format": "zip",
        "assertions": [],
        "pin_platform": None,
    },
}

# Every entry must carry exactly these keys (Plan §2). Enforced by _validate().
REQUIRED_KEYS = (
    "runs_on",
    "build_flags",
    "provision",
    "artifact_kind",
    "artifact_path",
    "app_executable",
    "archive_name",
    "archive_format",
    "assertions",
    "pin_platform",
)


def target_names():
    """Sorted list of valid target names."""
    return sorted(TARGETS)


def spec(target):
    """Returns TARGETS[target]; raises KeyError naming the valid targets."""
    try:
        return TARGETS[target]
    except KeyError:
        raise KeyError(
            f"unknown target {target!r}; valid targets: {', '.join(target_names())}"
        ) from None


def _validate():
    for name, entry in TARGETS.items():
        missing = [k for k in REQUIRED_KEYS if k not in entry]
        extra = [k for k in entry if k not in REQUIRED_KEYS]
        if missing or extra:
            raise ValueError(
                f"target {name!r}: missing keys {missing}, unexpected keys {extra}"
            )


_validate()
