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
  build_target  build_apps.py:2820-2845 (the positional `target` argparse accepts)
  app_executable macos/Runner/Configs/AppInfo.xcconfig:8 (PRODUCT_NAME),
                 windows/CMakeLists.txt:7 and linux/CMakeLists.txt:7 (BINARY_NAME)

``build_target`` vs the dict KEY. The key is the CI TARGET NAME (what
``ci.py --target`` takes and what a workflow matrix leg names);
``build_target`` is the positional ``scripts/build_apps.py`` is invoked with.
For five of the six they are identical. They are NOT identical for
``macos-x64``: build_apps.py has no separate Intel target, it has a
``--macos-arch`` FLAG on the one ``macos`` target (build_apps.py:2838-2840),
so that CI leg renders ``build_apps.py macos --macos-arch x86_64 …``. Keeping
the two names as separate fields is what lets one build entry point serve two
CI legs without any name-equality branching anywhere else (G-5).

``assert_platform`` is the artefact PLATFORM name the R-7 assertion suite
judges this target as (``assertions.platform_of``). It is neither the
architecture nor the runner: BOTH macOS legs declare "macos", so both stay
subject to run_suite()'s "a skip on the artefact's own platform is a FAILURE"
rule. See the macos-x64 entry's own comment for why inventing a per-arch
platform name would have silently disabled that rule for the whole leg.

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
        "build_target": "macos",
        "assert_platform": "macos",
        "runs_on": "macos-14",
        # --fetch-native: as of the HALCYON-MIGRATION campaign (2026-09, tag
        # v0.1.8) macOS is fetched from the ceyx release pin, the same as
        # windows/linux, rather than keeping its six dylibs committed. This CI
        # leg is a single fixed architecture (Apple silicon, runs_on above), so
        # it consumes the "macos-arm64" pin entry via pin_platform below — the
        # same one-leg-one-key shape windows/linux already use, not a new
        # architecture-aware mechanism. See scripts/ceyx_release_pin.json's
        # comment for the full decision and its minimum-OS consequence (the
        # bundled decoder stack now requires macOS 15 on Apple silicon / macOS
        # 14 on Intel at runtime — this project's user-facing declared minimum
        # of macOS 11 is unchanged and is a separate, application-layer
        # concern this migration does not alter).
        "build_flags": ["--fetch-native"],
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
            "H-DECODER-DEPS",
            "H-DECODER-HASH",
            "H-SIZED-SYMBOL",
            "H-SIZED-SYMBOL-NM",
        ],
        "pin_platform": "macos-arm64",
    },
    "macos-x64": {
        # Intel macOS, CROSS-COMPILED on the same Apple-silicon runner image the
        # arm64 leg uses. build_apps.py has no separate Intel target: it has one
        # `macos` target plus a `--macos-arch` flag (build_apps.py:2838-2840),
        # which sets FLUTTER_XCODE_ARCHS (2560-2565), selects the pin's
        # "macos-x86_64" asset via fetch_target_for() (1440-1467), and already
        # refuses to finish if the produced app's slices are not exactly
        # {x86_64} (2405) or the fetched dylib's are not (2702). Hence
        # build_target "macos" with the arch carried in build_flags.
        "build_target": "macos",
        # The artefact platform for the assertion suite is "macos", NOT a new
        # platform name. That is deliberate and load-bearing: assertions.py
        # treats a skip as a FAILURE only when the artefact's platform equals
        # the host's (Spec §4.5, the 2026-08-25 silently-skipped-gate lesson).
        # Inventing a "macos-x86_64" artefact platform would make every skip on
        # this leg "legitimate" — a missing nm, an unreadable manifest entry —
        # and the leg would report green while measuring nothing. Architecture
        # is not a platform here; it is asserted directly, by H-ARCH and
        # H-DECODER-ARCH, against expected_arch=x86_64.
        "assert_platform": "macos",
        # macos-14 (Apple silicon), not macos-13 (Intel): this leg is a
        # cross-compile, which is exactly what the local proof did, and it keeps
        # both macOS legs on one runner image rather than depending on the
        # retiring Intel image. The cost is stated, not hidden — see the
        # H-SIZED-SYMBOL omission in "assertions" below.
        "runs_on": "macos-14",
        "build_flags": ["--macos-arch", "x86_64", "--fetch-native"],
        # Identical to the arm64 leg: same Podfile, same gitignored
        # Flutter-Generated.xcconfig that only `pub get` creates.
        "provision": [["flutter", "pub", "get"], ["pod", "install"]],
        "artifact_kind": "app_bundle",
        # Same output path as the arm64 build — the two never coexist on one
        # runner, because each CI/release matrix leg builds exactly one of them.
        "artifact_path": "build/macos/Build/Products/Release/Halcyon.app",
        "app_executable": "Halcyon",
        "archive_name": "Halcyon-macos-x64-{version}.zip",
        "archive_format": "zip",
        # H-SIZED-SYMBOL (the functional FFI probe) is DELIBERATELY ABSENT, for
        # the same class of reason H-SIZED-SYMBOL-NM is absent on windows: the
        # instrument is structurally invalid here. The probe is
        # `dart run` + DynamicLibrary.open, and an arm64 dart process cannot
        # load an x86_64 dylib, so on this runner it could only ever report a
        # loader failure that says nothing about the artefact. It is omitted in
        # DATA, visibly, rather than silently skipped at run time. What replaces
        # it: H-DECODER-ARCH (the shipped dylib really is x86_64) and
        # H-SIZED-SYMBOL-NM / H-CEYX-SYMBOLS-NM (nm reads a foreign-arch Mach-O
        # file fine on any host, because it parses the file rather than loading
        # it). Runtime loadability on real Intel hardware is therefore NOT
        # measured by this leg and must not be claimed from a green run.
        "assertions": [
            "H-ARCH",
            "H-DECODER-PRESENT",
            "H-DECODER-ARCH",
            "H-DECODER-DEPS",
            "H-DECODER-HASH",
            "H-SIZED-SYMBOL-NM",
            "H-CEYX-SYMBOLS-NM",
        ],
        "pin_platform": "macos-x86_64",
    },
    "windows": {
        "build_target": "windows",
        "assert_platform": "windows",
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
        "build_target": "linux",
        "assert_platform": "linux",
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
        "build_target": "android-apk",
        "assert_platform": "android",
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
        "build_target": "web",
        # No manifest entry and no native artefact: platform_of() previously fell
        # back to the target name for this target, and "web" preserves that
        # exactly. Its assertion list is empty, so nothing consumes it.
        "assert_platform": "web",
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
    "build_target",
    "assert_platform",
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
