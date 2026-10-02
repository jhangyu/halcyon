"""Per-target CI data. DATA ONLY.

Frozen interface: Plan_ci_rewrite.md §2. G-5: this is the ONLY file under
``scripts/ci/`` allowed to state a per-platform fact — everywhere else, platform
is a parameter and the difference is a dict lookup. No ``import subprocess``
here, and no behaviour: a reader must be able to audit every platform fact by
reading one screen of literals against the workflow files they were copied from.

Provenance of every value below (transcribed byte-for-byte, not re-derived):
  build_flags   the pre-rewrite per-platform workflow build steps (the workflows
                now pass only --target; this table is the source)
  provision     same origin (linux apt step; macOS pod-install step)
  artifact_path build_apps.py flutter_artifact()
  archive_name  the pre-rewrite release.yml per-platform package steps
  build_target  build_apps.py make_parser() (the positional `target` argparse accepts)
  app_executable macos/Runner/Configs/AppInfo.xcconfig (PRODUCT_NAME),
                 windows/CMakeLists.txt and linux/CMakeLists.txt (BINARY_NAME)

``build_target`` vs the dict KEY. The key is the CI TARGET NAME (what
``ci.py --target`` takes and what a workflow matrix leg names);
``build_target`` is the positional ``scripts/build_apps.py`` is invoked with.
For five of the six they are identical. They are NOT identical for
``macos-x64``: build_apps.py has no separate Intel target, it has a
``--macos-arch`` FLAG on the one ``macos`` target (build_apps.py make_parser()),
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
and Linux is lowercase too ("halcyon") — the remaining difference is
capitalisation and the ".exe" suffix, not a stale project name.
``decoder_artifact`` / ``expected_arch`` are the shipped decoder library's
basename and architecture that H-DECODER-PRESENT / H-ARCH / H-DECODER-ARCH judge
this leg against (None where the target ships no decoder). ``ffi_manifest_key``
names this leg's entry in scripts/dng_ffi_artifacts.json, read only for the
symbol-table tool (nm/dumpbin + args) the -NM assertions share with the manual
checker; the json no longer names CI targets (forward reference, not a reverse
ci_target lookup that could silently match nothing).
``archive_name`` above names the *zip/tarball* and is deliberately
product-branded on all targets — the two must not be conflated.
"""

from __future__ import annotations

TARGETS: dict = {
    "macos": {
        "build_target": "macos",
        "assert_platform": "macos",
        "runs_on": "macos-14",
        # --fetch-native: as of the HALCYON-MIGRATION campaign (2026-09, tag
        # v0.1.8) macOS is fetched from the ceyx release pin, the same as
        # windows/linux, rather than keeping its dylibs committed (six at the
        # v0.1.8 tag; five since the v0.1.24 repin removed liblcms2.2.dylib).
        # This CI leg is a single fixed architecture (Apple silicon, runs_on above), so
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
        # see phases.provision()). The pub get is NOT optional and NOT a duplicate of the
        # one `flutter build` does implicitly: macos/Podfile (its Flutter-Generated.xcconfig check) raises unless
        # macos/Flutter/ephemeral/Flutter-Generated.xcconfig exists, and that
        # directory is gitignored (macos/.gitignore), so only pub get creates it.
        # The pre-rewrite workflow ran it immediately before pod install
        # (the pre-rewrite ci.yml macOS job); the rewrite dropped it, which is
        # the 2026-08-31 round-1 macOS provision failure.
        "provision": [
            {"argv": ["flutter", "pub", "get"], "cwd": None},
            {"argv": ["pod", "install"], "cwd": "macos"},
        ],
        "artifact_kind": "app_bundle",
        "artifact_path": "build/macos/Build/Products/Release/Halcyon.app",
        # macos/Runner/Configs/AppInfo.xcconfig — PRODUCT_NAME = Halcyon;
        # the binary lives at Halcyon.app/Contents/MacOS/Halcyon.
        "app_executable": "Halcyon",
        "archive_name": "Halcyon-macos-arm64-{version}.zip",
        "archive_format": "zip",
        "assertions": [
            "H-ARCH",
            "H-DECODER-PRESENT",
            "H-DECODER-DEPS",
            "H-DECODER-HASH",
            "H-CEYX-SYMBOLS",
            "H-CEYX-SYMBOLS-NM",
        ],
        "pin_platform": "macos-arm64",
        "decoder_artifact": "libdng_decoder_native.dylib",
        "expected_arch": "arm64",
        "ffi_manifest_key": "macos",
    },
    "macos-x64": {
        # Intel macOS, CROSS-COMPILED on the same Apple-silicon runner image the
        # arm64 leg uses. build_apps.py has no separate Intel target: it has one
        # `macos` target plus a `--macos-arch` flag (build_apps.py make_parser()),
        # which sets FLUTTER_XCODE_ARCHS (build_flutter()), selects the pin's
        # "macos-x86_64" asset via fetch_target_for(), and already
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
        # H-CEYX-SYMBOLS omission in "assertions" below.
        "runs_on": "macos-14",
        "build_flags": ["--macos-arch", "x86_64", "--fetch-native"],
        # Identical to the arm64 leg: same Podfile, same gitignored
        # Flutter-Generated.xcconfig that only `pub get` creates.
        "provision": [
            {"argv": ["flutter", "pub", "get"], "cwd": None},
            {"argv": ["pod", "install"], "cwd": "macos"},
        ],
        "artifact_kind": "app_bundle",
        # Same output path as the arm64 build — the two never coexist on one
        # runner, because each CI/release matrix leg builds exactly one of them.
        "artifact_path": "build/macos/Build/Products/Release/Halcyon.app",
        "app_executable": "Halcyon",
        "archive_name": "Halcyon-macos-x64-{version}.zip",
        "archive_format": "zip",
        # H-CEYX-SYMBOLS (the functional FFI probe) is DELIBERATELY ABSENT, for
        # the same class of reason H-CEYX-SYMBOLS-NM is absent on windows: the
        # instrument is structurally invalid here. The probe is
        # `dart run` + DynamicLibrary.open, and an arm64 dart process cannot
        # load an x86_64 dylib, so on this runner it could only ever report a
        # loader failure that says nothing about the artefact. It is omitted in
        # DATA, visibly, rather than silently skipped at run time. What replaces
        # it: H-DECODER-ARCH (the shipped dylib really is x86_64) and
        # H-CEYX-SYMBOLS-NM (nm reads a foreign-arch Mach-O
        # file fine on any host, because it parses the file rather than loading
        # it). Runtime loadability on real Intel hardware is therefore NOT
        # measured by this leg and must not be claimed from a green run.
        # H-CEYX-SYMBOLS (the multi-symbol functional probe, clause 10) is
        # DELIBERATELY ABSENT here for the identical reason: it is `_run_probe`
        # with the full CEYX_SYMBOLS set, still `dart run` + DynamicLibrary.open,
        # so an arm64 dart process still cannot load this leg's x86_64 dylib.
        # A Rosetta-2-based functional probe for this leg was evaluated and
        # rejected by user ruling 2026-09-12
        # (docs/logs/2026-09-12/platform-parity-user-rulings.md, OQ-C3): the
        # extra x86_64 Dart SDK download per run is not worth it, and Intel
        # runtime proof remains a disclosed limitation of this leg. No spike
        # was run. Do not re-open without new grounds.
        "assertions": [
            "H-ARCH",
            "H-DECODER-PRESENT",
            "H-DECODER-ARCH",
            "H-DECODER-DEPS",
            "H-DECODER-HASH",
            "H-CEYX-SYMBOLS-NM",
        ],
        "pin_platform": "macos-x86_64",
        "decoder_artifact": "libdng_decoder_native.dylib",
        "expected_arch": "x86_64",
        "ffi_manifest_key": "macos-x86_64",
    },
    "windows": {
        "build_target": "windows",
        "assert_platform": "windows",
        "runs_on": "windows-latest",
        # --fetch-native, not plain auto: ceyx still carries a committed
        # dng_decoder_native.dll (hand-built, no S4 colour-gate record). Auto-fetch
        # only fires when the destination is ABSENT, so without this flag Windows
        # would keep shipping that unvalidated binary.
        "build_flags": ["--fetch-native"],
        "provision": [],
        "artifact_kind": "dir",
        "artifact_path": "build/windows/x64/runner/Release",
        # windows/CMakeLists.txt — set(BINARY_NAME "halcyon"); LOWERCASE, and
        # the runner is emitted as <BINARY_NAME>.exe.
        "app_executable": "halcyon.exe",
        "archive_name": "Halcyon-windows-x64-{version}.zip",
        "archive_format": "zip",
        # H-CEYX-SYMBOLS-NM is deliberately absent: the symbol-table instrument is
        # structurally invalid on PE (no default export visibility). PL-9.
        "assertions": [
            "H-ARCH",
            "H-DECODER-PRESENT",
            "H-DECODER-DEPS",
            "H-DECODER-HASH",
            "H-CEYX-SYMBOLS",
            "H-ENGINE-DELAYLOAD",
        ],
        "pin_platform": "windows",
        "decoder_artifact": "dng_decoder_native.dll",
        "expected_arch": "x86_64",
        "ffi_manifest_key": "windows",
    },
    "linux": {
        "build_target": "linux",
        "assert_platform": "linux",
        "runs_on": "ubuntu-latest",
        # --fetch-native, not plain auto: same rationale as the windows entry
        # above — auto-fetch only fires when the destination is ABSENT, so a
        # stale .so left in plugin/linux/Libraries/ by a future dev or runner
        # would otherwise be shipped silently (rootcause-native-capability.md
        # §A3, S-A3).
        "build_flags": ["--fetch-native"],
        "provision": [
            {"argv": ["sudo", "apt-get", "update"], "cwd": None},
            {"argv": ["sudo", "apt-get", "install", "-y", "ninja-build", "libgtk-3-dev"], "cwd": None},
        ],
        # The arch segment is host-dependent (build_apps.py flutter_artifact()), hence glob.
        "artifact_kind": "glob_dir",
        "artifact_path": "build/linux/*/release/bundle",
        # linux/CMakeLists.txt — set(BINARY_NAME "halcyon").
        "app_executable": "halcyon",
        "archive_name": "Halcyon-linux-x64-{version}.tar.gz",
        "archive_format": "gztar",
        "assertions": [
            "H-ARCH",
            "H-DECODER-PRESENT",
            # ELF branch of H-DECODER-DEPS: the decoder NEEDs libheif.so.1, which
            # NEEDs libde265.so.0 (readelf -d, hal-r2q-linux-deps.md); a bundle
            # missing either fails dlopen naming only the decoder.
            "H-DECODER-DEPS",
            "H-DECODER-HASH",
            "H-CEYX-SYMBOLS",
            "H-CEYX-SYMBOLS-NM",
        ],
        "pin_platform": "linux",
        "decoder_artifact": "libdng_decoder_native.so",
        "expected_arch": "x86_64",
        "ffi_manifest_key": "linux",
    },
    "windows-arm": {
        # Native Windows-on-ARM runner leg (user ruling 2026-09-30, armci
        # campaign contract 3a: proof happens on GitHub CI, not locally). Same
        # build entry point as "windows" (build_apps.py has no separate arm
        # target); the architecture is carried by the runner (runs_on below)
        # and by pin_platform, not by a name-equality branch (G-5).
        "decoder_artifact": "dng_decoder_native.dll",
        "expected_arch": "arm64",
        "ffi_manifest_key": "windows-arm64",
        "build_target": "windows",
        # Artefact platform is "windows", NOT "windows-arm64": same load-bearing
        # reason as macos-x64 above (a per-arch platform name would never equal
        # host_platform() and would silently disable the skip-is-failure rule).
        # Architecture is asserted as architecture, by H-ARCH against the
        # manifest entry's expected_arch=arm64.
        "assert_platform": "windows",
        "runs_on": "windows-11-arm",
        # --desktop-arch arm64 (build_apps.py fetch_target_for): explicit arch
        # selector, fails loudly if the host is not arm64. --fetch-native for
        # the same reason as the windows entry above.
        "build_flags": ["--desktop-arch", "arm64", "--fetch-native"],
        # Flutter picks its Windows build target from the Dart VM's own ABI
        # (flutter_tools base/os.dart:479-485, build_windows.dart:67-69), and
        # flutter-action installs an SDK with x64 Dart — so without this the leg
        # would build windows-x64 under emulation. bin/internal/update_dart_sdk.ps1
        # picks the arm64 Dart zip when $env:PROCESSOR_ARCHITECTURE is ARM64
        # (lines 55-62; falls back to x64 if the engine has no arm64 zip). The
        # stamp (update_dart_sdk.ps1:22) must go first or the refresh is skipped.
        # native_dart.py fails loudly unless `dart --version` then reports
        # windows_arm64; then precache fetches the arm64 engine artifacts.
        "provision": [
            {"argv": ["python3", "scripts/ci/native_dart.py",
                      "--stamp", "bin/cache/engine-dart-sdk.stamp",
                      "--dart", "bin/cache/dart-sdk/bin/dart.exe",
                      "--expect", "windows_arm64",
                      "--", "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                      "-File", "{flutter_root}/bin/internal/update_dart_sdk.ps1"],
             "cwd": None},
            {"argv": ["flutter", "precache", "--windows"], "cwd": None},
        ],
        "artifact_kind": "dir",
        # Flutter's Windows desktop output dir is build/windows/<arch>/runner/
        # <mode>; the arch segment is "arm64" for an arm64 build (the x64 leg's
        # path above has "x64"). UNVERIFIED on Flutter 3.44.6 until the first CI
        # run (contract ruling 1a: if Flutter windows-arm64 is unsupported the
        # leg STOPS and reports).
        "artifact_path": "build/windows/arm64/runner/Release",
        # windows/CMakeLists.txt:7 — same BINARY_NAME as the x64 leg.
        "app_executable": "halcyon.exe",
        "archive_name": "Halcyon-windows-arm64-{version}.zip",
        "archive_format": "zip",
        # Same list as "windows" (H-SIZED-SYMBOL/-NM no longer exist in
        # assertions.SUITE; H-CEYX-SYMBOLS replaced them). H-CEYX-SYMBOLS
        # (dart-run + DynamicLibrary.open) is KEPT, unlike macos-x64: the runner
        # is native arm64 and the DLLs are arm64, so loading is a valid
        # instrument. TRUE precondition = the Dart process is arm64 (see
        # provision); if it is not, the probe fails naming a loader error — to be
        # judged on CI, not pre-omitted (contract 3a allows iteration here).
        # H-CEYX-SYMBOLS-NM stays absent: the PE structural reason (no default
        # export visibility, PL-9) is architecture-independent.
        "assertions": [
            "H-ARCH",
            "H-DECODER-PRESENT",
            "H-DECODER-DEPS",
            "H-DECODER-HASH",
            "H-CEYX-SYMBOLS",
            # Same as "windows": reads the PE import/delay-import directories
            # structurally (assertions.py _assert_engine_delayload, valid_on
            # windows). Architecture-independent: windows/CMakeLists.txt:64-67
            # applies /DELAYLOAD to every Windows build, and the std-handle
            # hazard it guards (EnsureStdOutputHandles before the engine CRT
            # initialises) is the same on ARM64.
            "H-ENGINE-DELAYLOAD",
        ],
        "pin_platform": "windows-arm64",
    },
    "linux-arm": {
        # Native arm64 Linux runner leg (armci campaign contract). Same build
        # entry point as "linux"; architecture carried by runs_on and
        # pin_platform. assert_platform "linux" for the same reason as
        "decoder_artifact": "libdng_decoder_native.so",
        "expected_arch": "aarch64",
        "ffi_manifest_key": "linux-arm64",
        # windows-arm/macos-x64 above.
        "build_target": "linux",
        "assert_platform": "linux",
        "runs_on": "ubuntu-24.04-arm",
        # --desktop-arch arm64: see windows-arm; --fetch-native as for linux.
        "build_flags": ["--desktop-arch", "arm64", "--fetch-native"],
        # Identical to "linux": ubuntu-24.04-arm is the same distro release on
        # arm64, and ninja-build/libgtk-3-dev are published for arm64.
        "provision": [
            {"argv": ["sudo", "apt-get", "update"], "cwd": None},
            {"argv": ["sudo", "apt-get", "install", "-y", "ninja-build", "libgtk-3-dev"], "cwd": None},
            # subosito/flutter-action picks the SDK by runner arch and Flutter
            # 3.44.6 publishes no Linux arm64 SDK archive (round-1 review
            # blocker), so the workflow skips the action for this leg
            # (matrix flutter_source: git) and the SDK is cloned at the tag
            # here. The tag MUST equal the workflows' flutter-version — a
            # policy test in test_policy.py enforces it. install_flutter.py
            # appends <dest>/bin to $GITHUB_PATH for the later build steps.
            {"argv": ["python3", "scripts/ci/install_flutter.py",
                      "--tag", "3.44.6", "--dest", "~/flutter"],
             "cwd": None},
        ],
        # build/linux/<arch>/release/bundle — glob covers arm64 (build_apps.py
        # flutter_artifact globs the arch segment).
        "artifact_kind": "glob_dir",
        "artifact_path": "build/linux/*/release/bundle",
        "app_executable": "halcyon",
        "archive_name": "Halcyon-linux-arm64-{version}.tar.gz",
        "archive_format": "gztar",
        # Same list as "linux" (H-SIZED-SYMBOL/-NM are gone from
        # assertions.SUITE): the runner is native arm64 and the .so is aarch64,
        # so the dart-run probe H-CEYX-SYMBOLS can load it (true precondition,
        # unlike macos-x64) and nm -D reads ELF natively (H-CEYX-SYMBOLS-NM).
        # H-ARCH expects aarch64 via expected_arch.
        "assertions": [
            "H-ARCH",
            "H-DECODER-PRESENT",
            # ELF branch of H-DECODER-DEPS: the decoder NEEDs libheif.so.1, which
            # NEEDs libde265.so.0 (readelf -d, hal-r2q-linux-deps.md); a bundle
            # missing either fails dlopen naming only the decoder.
            "H-DECODER-DEPS",
            "H-DECODER-HASH",
            "H-CEYX-SYMBOLS",
            "H-CEYX-SYMBOLS-NM",
        ],
        "pin_platform": "linux-arm64",
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
        "decoder_artifact": "libdng_decoder_native.so",
        "expected_arch": "aarch64",
        "ffi_manifest_key": "android",
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
        "decoder_artifact": None,
        "expected_arch": None,
        "ffi_manifest_key": None,
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
    "decoder_artifact",
    "expected_arch",
    "ffi_manifest_key",
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
        for item in entry["provision"]:
            if not isinstance(item, dict) or set(item) != {"argv", "cwd"}:
                raise ValueError(
                    f"target {name!r}: provision item {item!r} must be a dict with "
                    "exactly the keys 'argv' and 'cwd' (cwd: repo-root-relative str or None)"
                )


_validate()
