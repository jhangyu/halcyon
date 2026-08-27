#!/usr/bin/env python3
"""build_apps.py - the single build entry point for Halcyon (native + Flutter).

Replaces `scripts/build.sh` (macOS/Android/web/Windows/Linux Flutter builds) and
`scripts/windows/build_windows.py` (Windows native DNG decoder + Flutter build).
One script, one behaviour, no per-platform drift: every target goes through the
same phases in the same order.

    Phase 0   host + tool checks for the requested target   (fail loudly, early)
    Phase 0b  Halide v21 distribution, if a native build is due
    Phase 1   native dng_decoder_native build + library placement
    Phase 2   flutter pub get + flutter build <target>
    Phase 3   artifact verification (+ the Windows manual-verification protocol)

Layouts understood (both auto-detected, override with --root):
    <repo>/scripts/build_apps.py           with ../ceyx as sibling
    <zip root>/build_apps.py               with Halcyon/ + ceyx/

Python 3 stdlib only. Run `python3 scripts/build_apps.py --help` for usage.


===============================================================================
CAPABILITY MAP (acceptance A6) - every capability of the two predecessors
===============================================================================

--- scripts/build.sh (224 lines, main) -------------------------------------
build.sh:5    default target macos                              REPRODUCED (main:TARGET default)
build.sh:6    BUILD_MODE env var, default release                REPRODUCED (resolve_mode)
build.sh:8    usage/--help text listing targets                  REPRODUCED (argparse + TARGET_HELP)
build.sh:35   log()/fail() formatting ("==> ", "Error: ")        REPRODUCED (log/fail)
build.sh:44   macos_config_name Debug/Profile/Release            REPRODUCED (macos_config_name)
build.sh:52   print_output_hint per target                       REPRODUCED+FIXED (verify_flutter_artifact
                                                                 resolves the REAL path and fails if it is
                                                                 missing; build.sh printed a hard-coded
                                                                 "photo_selector_flutter.app" that has been
                                                                 wrong since PRODUCT_NAME became Halcyon -
                                                                 macos/Runner/Configs/AppInfo.xcconfig:8)
build.sh:77   host_os() Darwin/Linux/MINGW mapping               REPRODUCED (host_os)
build.sh:86   configure_android_java JDK 25 -> 21 -> 17          REPRODUCED (configure_android_java,
                                                                 same three paths, same order)
build.sh:108  supports_target host gating                        REPRODUCED (supports_target)
build.sh:125  hard fail on unsupported target                    REPRODUCED (build_target)
build.sh:129  flutter build macos/apk/appbundle/web/windows/linux REPRODUCED (FLUTTER_BUILD_ARGS)
build.sh:135  android / android-apk / android-aab aliases        REPRODUCED (TARGETS)
build.sh:169  all = every host-supported target, skip others     REPRODUCED (build_all, same 5-target list,
                                                                 same skip-not-fail semantics)
build.sh:182  arg parsing --debug/--profile/--release anywhere   REPRODUCED (argparse mode flags)
build.sh:211  "Flutter is not available in PATH" precheck        REPRODUCED (check_target, and now also
                                                                 covered by --check)
build.sh:213  cd to repo root before building                    REPRODUCED (cwd= on every run)
build.sh:216  flutter pub get before building                    REPRODUCED (phase 2)
DROPPED: nothing.

--- windows-port:scripts/windows/build_windows.py (624 lines) ---------------
bw:42    Halide commit/asset/URL pin                             REPRODUCED (HALIDE_COMMIT/HALIDE_URL),
                                                                 generalised to every host arch using the
                                                                 same table as the upstream
                                                                 native/scripts/fetch_halide_v21_dist.sh
bw:50    phase/step/ok/warn/fail + warning counter               REPRODUCED
bw:80    decode_bytes utf-8/mbcs fallback                        REPRODUCED
bw:96    _read_registry_env / refresh_env_from_registry          REPRODUCED (Windows-only, winreg imported
                                                                 lazily - the original's module-level
                                                                 `import winreg` made the file unimportable
                                                                 on macOS/Linux, which is why it could not
                                                                 be the single entry point)
bw:134   locate_vs_install via vswhere                           REPRODUCED
bw:155   ensure_msvc_env, vcvars64.bat via shell=True            REPRODUCED (comment on why shell=True is
                                                                 unavoidable kept verbatim in intent)
bw:200   run_checked, .bat/.cmd -> shell=True, streamed output   REPRODUCED (run_checked)
bw:244   download_with_progress                                  REPRODUCED
bw:269   extract_halide skipping share/doc/*                     REPRODUCED (+ tar.gz support for POSIX
                                                                 hosts, which the original never needed)
bw:285   ensure_halide + lib/Release/Halide.lib mirroring        REPRODUCED (ensure_halide)
bw:334   third_party/halide/VERSION provenance stamp             REPRODUCED
bw:344   --root                                                  REPRODUCED
bw:345   --cfa-sample-dng colour gate (runbook S4)               REPRODUCED
bw:346   --skip-flutter-build                                    REPRODUCED
bw:347   --native-target T... iteration aid                      REPRODUCED
bw:364   packaged layout Halcyon/ + ceyx/                        REPRODUCED (resolve_layout, and the
                                                                 in-repo sibling layout as well)
bw:380   CMakePresets.json windows-vulkan presence check         REPRODUCED, generalised: the preset name
                                                                 required is the one for the target being
                                                                 built (NATIVE_SPECS)
bw:400   clang-cl / cmake>=3.14 / ninja / VULKAN_SDK checks      REPRODUCED (check_native, Windows rows)
bw:444   vulkaninfo / nasm soft warnings                         REPRODUCED
bw:456   flutter presence (soft if --skip-flutter-build)         REPRODUCED
bw:482   cmake --preset / --build --preset --target              REPRODUCED (build_native)
bw:502   built-DLL existence assertion                           REPRODUCED
bw:532   copy artifact into plugin/<os>/Libraries/               REPRODUCED, generalised to
                                                                 macos/.dylib, windows/.dll,
                                                                 android/jniLibs/arm64-v8a/.so
bw:538   "this tree is not a git checkout" commit note           DELIBERATELY DROPPED: in-repo runs (the
                                                                 normal case now) can and should commit
                                                                 normally; the note is printed only when
                                                                 the packaged layout is detected.
bw:550   flutter pub get + flutter build windows --release       REPRODUCED, mode is no longer hard-coded
                                                                 to --release (--debug/--profile work).
bw:553   DLL-next-to-exe packaging check + S5 diagnostics        REPRODUCED (verify_windows_bundle)
bw:590   Phase 3 manual verification protocol print              REPRODUCED (print_windows_protocol)
bw:614   exit banner with warning count                          REPRODUCED
DROPPED: only bw:538 (see above).

--- Added here, in neither predecessor -------------------------------------
  * ios target (build.sh had none).
  * --check: host/tool preflight with a non-zero exit, runnable standalone.
  * --native auto|always|never: one rule for "is a native rebuild due?".
  * Native builds for macos/android, not just windows.

--- Reconciliation with docs/logs/2026-08-22/review-halcyon-winport-buildscript.md
B1  colour gate skipped -> green exit + library placed   FIXED: skipping the gate now
                                                         requires --no-colour-gate, and the
                                                         acknowledged skip still exits 2
                                                         (build_native / finish)
B2  top-level `import winreg`                            FIXED: lazy, Windows-only
S1  Halide fetched with no integrity check               PARTIAL: optional --halide-sha256,
                                                         the observed sha256 is recorded in
                                                         VERSION and read back on later runs
                                                         (stale/drift detection), one-top-level
                                                         assert, archive errors -> fail(),
                                                         socket timeout. No pinned hash ships:
                                                         nobody has a trustworthy one yet.
S2  MSVC env accepted without an arch check              FIXED: VSCMD_ARG_TGT_ARCH must be x64
S3  PATH precedence inverted, %VARS% unexpanded          FIXED: process > user > machine,
                                                         expandvars per entry
S4  checks that degrade instead of failing               FIXED: unparseable cmake version now
                                                         fails; Libraries parent is validated,
                                                         not fabricated; SubprocessError caught;
                                                         vswhere -requires; vulkaninfo is really
                                                         run and apiVersion parsed
S5  run_checked not actually streaming, stdin open       FIXED: text mode + line buffering,
                                                         stdin=DEVNULL, resolved exe reused
S6  shell=True + argv leaves cmd metacharacters          FIXED: .bat/.cmd arguments carrying cmd
                                                         metacharacters are refused, loudly
S7  "every phase is idempotent" hint is false            FIXED: hint reworded; --clean added;
                                                         a stale photo_selector_flutter CMake
                                                         cache is detected and named
S8  nasm warn claims SIMD-off is safe                    FIXED: wording admits the parity
                                                         question is unverified; the standard
                                                         install location is probed
S9  package_windows.sh / README drift                    NOT MINE: that is the merge-time
                                                         cleanup of files I must not edit
r21 vulkaninfo advisory that checks nothing              FIXED (made real)
r33 unconditional "not a git checkout" advisory          FIXED (packaged layout only)
r41 Windows Developer Mode / symlink pre-check           ADDED
r42 --clean / stale target-name detection                ADDED
r43 host-OS assertion before platform phases             ADDED (supports_target)

--- User rulings, round 2 (contract "User decisions - round 2")
B1 severity downgraded (the shipped DLL's colour output was compared against
   macOS by the user), but the mechanism stands: a run whose correctness gate
   never executed must not report success. Unchanged here.
S1 accepted: HALIDE_SHA256 pins every asset this script can fetch; verified
   after download and before extraction; a mismatch quarantines the file.
PL-6: macOS builds arm64 only (MACOS_DEFAULT_ARCH). Intel is parked because the
   prebuilt decoder dylib is arm64-only, so a universal app's x86_64 slice
   links without the native decoder - ld only WARNS about that, which is how it
   went unnoticed. verify_macos_slices() now fails the build instead.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import typing
import urllib.request
import zipfile
from pathlib import Path

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------
HALIDE_VERSION = "21.0.0"
HALIDE_COMMIT = "b629c80de18f1534ec71fddd8b567aa7027a0876"

# Mirrors native/scripts/fetch_halide_v21_dist.sh's uname mapping. Keeping the
# table here rather than shelling out to that script is deliberate: it is bash,
# and the Windows host has no guaranteed bash.
HALIDE_PLATFORMS = {
    ("macos", "arm64"): ("arm-64-osx", "tar.gz"),
    ("macos", "x86_64"): ("x86-64-osx", "tar.gz"),
    ("linux", "arm64"): ("arm-64-linux", "tar.gz"),
    ("linux", "x86_64"): ("x86-64-linux", "tar.gz"),
    ("windows", "x86_64"): ("x86-64-windows", "zip"),
}

# sha256 of each Halide asset. HALIDE_COMMIT only composes a FILENAME - GitHub
# release assets are mutable by anyone with push rights, so the name anchors
# nothing. These digests were read from the GitHub release API on 2026-08-22:
#   curl -s https://api.github.com/repos/halide/Halide/releases/tags/v21.0.0
#     | python3 -c "import json,sys; [print(a['name'], a.get('digest'))
#                                     for a in json.load(sys.stdin)['assets']]"
#
# ponytail: THESE ARE TRUST-ON-FIRST-USE DIGESTS, NOT AN INDEPENDENTLY VERIFIED
# PIN. They were obtained from the same authority that serves the bytes, on one
# machine, on one date. What that buys: any FUTURE change to an asset is caught.
# What it does NOT buy: if an asset was already substituted before 2026-08-22,
# these values faithfully record the substituted bytes and this check will pass.
# Upstream ships no .sha256/.asc/.sig asset and its release notes list no
# checksums (verified 2026-08-22: 8 assets, none checksum-like), so there is no
# second source to check against from inside this script.
# Upgrade path to a real pin - a HUMAN action, do not automate it away:
#   1. Have a second person, on a different machine and network, download the
#      same asset and compute `shasum -a 256`. Corroboration from an independent
#      observer is the only thing that turns TOFU into a pin.
#   2. If it matches, record WHO verified it and WHEN next to the value here.
#   3. If it differs, stop - that is the attack this table exists to catch.
# Re-print with: python3 scripts/build_apps.py --print-halide-pins
HALIDE_SHA256 = {
    "arm-64-osx": "040a6fbde5ba264870df4975138417ce2ff2c8e9de550302c8b17f36c36e5afa",
    "x86-64-osx": "d7d26c91adcfe62528e20e248ba673aa635de519669b19c47e5a367f856a8ab0",
    "arm-64-linux": "6fa8be9a556ddf3e899a0db59af84d69d0bebbf91ead90c03f90f731ab314d95",
    "x86-64-linux": "b56139ddc5d863486b9b339e1c9b7cc3f6aadd4dd8a2eff2202e79ca68706091",
    "x86-64-windows": "4efec94b7c8958b1ae0125a73245a148e4c98dbb54f2678bc34c6abe36ee899a",
}

# The user parked Intel/x86_64 macOS support (PL-6): the prebuilt decoder dylib
# is arm64-only, so a universal app links its x86_64 slice without the native
# decoder. Forwarded to xcodebuild via FLUTTER_XCODE_ARCHS, which flutter_tools
# passes straight through (flutter_tools/lib/src/macos/build_macos.dart:258 ->
# ios/xcodeproj.dart:442). No file under macos/ needs to change.
MACOS_DEFAULT_ARCH = "arm64"

# JDK search order copied verbatim from scripts/build.sh:87-89.
MACOS_JDK_CANDIDATES = [
    ("25", "/Library/Java/JavaVirtualMachines/temurin-25.jdk/Contents/Home"),
    ("21", "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"),
    ("17", "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"),
]

# target -> flutter build arguments (build.sh:129-161)
FLUTTER_BUILD_ARGS = {
    "macos": ["macos"],
    "ios": ["ios"],
    "android": ["apk"],
    "android-apk": ["apk"],
    "android-aab": ["appbundle"],
    "web": ["web"],
    "windows": ["windows"],
    "linux": ["linux"],
}

TARGET_HELP = [
    ("macos", "macOS app. Default target. Requires a macOS host."),
    ("ios", "iOS app (--no-codesign unless --ios-codesign). macOS host."),
    ("android", "Android APK. Alias of android-apk."),
    ("android-apk", "Android APK."),
    ("android-aab", "Android App Bundle."),
    ("web", "Web app."),
    ("windows", "Windows desktop app. Requires a Windows host."),
    ("linux", "Linux desktop app. Requires a Linux host."),
    ("all", "Every target supported by the current host."),
]
TARGETS = [name for name, _ in TARGET_HELP]

# build.sh:171 - `all` is this list, host-filtered, skipping (not failing on)
# what this host cannot build. ios is intentionally NOT in it: build.sh never
# had it, and an unattended `all` should not need signing decisions.
ALL_TARGETS = ["macos", "android-apk", "web", "windows", "linux"]

# Which native library each target needs, and how to build it. A target absent
# from this table has no native decoder (web, ios, linux today).
NATIVE_SPECS = {
    "macos": {
        "preset": "macos-metal",
        "build_dir": "build",
        "artifact": "libdng_decoder_native.dylib",
        "dest": Path("plugin") / "macos" / "Libraries",
        "stage1_preset": None,
    },
    "windows": {
        "preset": "windows-vulkan",
        "build_dir": "build-windows",
        "artifact": "dng_decoder_native.dll",
        "dest": Path("plugin") / "windows" / "Libraries",
        "stage1_preset": None,
    },
    "android": {
        "preset": "android-vulkan",
        "build_dir": str(Path("build-android") / "android-arm64"),
        "artifact": "libdng_decoder_native.so",
        "dest": Path("plugin") / "android" / "src" / "main" / "jniLibs" / "arm64-v8a",
        # Android is the one two-stage build: host generators first (W-stage1).
        "stage1_preset": "android-vulkan-stage1",
    },
}

# Phase 2 (HEIC): the vendored libheif/libde265 distribution, produced by
# ceyx's native/scripts/fetch_heif_deps.sh. Only macOS is VERIFIED in phase 2;
# the Windows and Linux rows exist so the readiness check reports them, not
# because either has been run (spec section 7.3 records that build_apps.py's
# Windows native path has never run end to end).
HEIF_DIST = Path("native") / "third_party" / "heif-dist"
HEIF_RUNTIME_LIBS = {
    "macos": ["libheif.1.dylib", "libde265.0.dylib"],
    "windows": ["heif.dll", "libde265.dll"],
    "linux": ["libheif.so.1", "libde265.so.0"],
}
HEIF_VERIFIED_TARGETS = ("macos",)

WARNING_COUNT = 0
CURRENT_PHASE = "startup"
# Set when a native library was placed without the runbook S4 colour gate. It
# is why this script can exit non-zero on an otherwise successful build.
COLOUR_GATE_SKIPPED = False


# --------------------------------------------------------------------------
# Output helpers (build.sh:35 log/fail, build_windows.py:50-77 phase/step/ok)
# --------------------------------------------------------------------------
def phase(name):
    global CURRENT_PHASE
    CURRENT_PHASE = name
    print()
    print(f"==> {name}")


def log(msg):
    print()
    print(f"==> {msg}")


def step(msg):
    print(f"    {msg}")


def ok(msg):
    print(f"    [ok]   {msg}")


def warn(msg):
    global WARNING_COUNT
    WARNING_COUNT += 1
    print(f"    [warn] {msg}")


def fail(msg, hints=None) -> "typing.NoReturn":
    print()
    print(f"ERROR in {CURRENT_PHASE}: {msg}", file=sys.stderr)
    for h in hints or []:
        print(f"       -> {h}", file=sys.stderr)
    print(file=sys.stderr)
    sys.exit(1)


def decode_bytes(b):
    if b is None:
        return ""
    for enc in ("utf-8", "mbcs"):
        try:
            return b.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return b.decode("utf-8", errors="replace")


# --------------------------------------------------------------------------
# Host detection (build.sh:77)
# --------------------------------------------------------------------------
def host_os():
    s = sys.platform
    if s == "darwin":
        return "macos"
    if s.startswith("linux"):
        return "linux"
    if s in ("win32", "cygwin", "msys"):
        return "windows"
    return "unknown"


def host_arch():
    m = platform.machine().lower()
    if m in ("arm64", "aarch64"):
        return "arm64"
    if m in ("x86_64", "amd64"):
        return "x86_64"
    return m


def supports_target(target):
    """build.sh:108 - windows/linux/macos/ios only build on their own OS."""
    host = host_os()
    if target in ("macos", "ios"):
        return host == "macos"
    if target == "windows":
        return host == "windows"
    if target == "linux":
        return host == "linux"
    if target in ("android", "android-apk", "android-aab", "web"):
        return True
    return False


def which(name):
    return shutil.which(name)


# --------------------------------------------------------------------------
# Layout resolution
# --------------------------------------------------------------------------
class Layout:
    def __init__(self, halcyon, decoder, packaged):
        self.halcyon = halcyon
        self.decoder = decoder
        self.packaged = packaged

    @property
    def native(self):
        return self.decoder / "native"


def resolve_layout(root_arg):
    """Find Halcyon/ and ceyx/ in either supported layout."""
    if root_arg:
        root = Path(root_arg).resolve()
        candidates = [(root / "Halcyon", root / "ceyx", True),
                      (root, root.parent / "ceyx", False)]
    else:
        here = Path(__file__).resolve().parent
        candidates = [
            # in-repo: scripts/build_apps.py, decoder is a sibling of the repo
            (here.parent, here.parent.parent / "ceyx", False),
            # packaged zip root: build_apps.py next to Halcyon/
            (here / "Halcyon", here / "ceyx", True),
        ]

    for halcyon, decoder, packaged in candidates:
        if (halcyon / "pubspec.yaml").exists():
            return Layout(halcyon.resolve(), decoder, packaged)

    fail(
        "could not locate the Halcyon checkout (no pubspec.yaml found).",
        hints=[
            "Run this script from inside the repo as scripts/build_apps.py,",
            "or pass --root <folder holding Halcyon/ and ceyx/>.",
        ],
    )


# --------------------------------------------------------------------------
# Environment bootstrap
# --------------------------------------------------------------------------
def configure_android_java():
    """build.sh:86 - pick a JDK for Gradle on macOS. Same paths, same order."""
    if host_os() != "macos":
        return
    for label, home in MACOS_JDK_CANDIDATES:
        if os.access(os.path.join(home, "bin", "java"), os.X_OK):
            os.environ["JAVA_HOME"] = home
            os.environ["PATH"] = os.path.join(home, "bin") + os.pathsep + os.environ.get("PATH", "")
            log(f"Using JDK {label} for Android build: {home}")
            return
    # build.sh fell through silently here; a warning is cheap and the Gradle
    # failure it prevents is not.
    warn("no Temurin 25 / openjdk@21 / openjdk@17 found - falling back to the JDK already on PATH.")


def _read_registry_env(root, subkey):
    import winreg  # type: ignore[import]  # Windows-only; never imported at module level

    out = {}
    try:
        with winreg.OpenKey(root, subkey) as k:
            i = 0
            while True:
                try:
                    name, value, _ = winreg.EnumValue(k, i)
                except OSError:
                    break
                out[name] = value
                i += 1
    except OSError:
        pass
    return out


def refresh_env_from_registry():
    """Windows: this process's inherited env can be stale relative to tools
    installed after the parent shell started (build_windows.py:113)."""
    if host_os() != "windows":
        return
    import winreg  # type: ignore[import]

    machine = _read_registry_env(
        winreg.HKEY_LOCAL_MACHINE,
        r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment",
    )
    user = _read_registry_env(winreg.HKEY_CURRENT_USER, "Environment")

    # Precedence is process > user > machine (build_windows.py:120-125 had it
    # inverted, so a toolchain the user deliberately front-loaded in their shell
    # lost to the machine-wide PATH). REG_EXPAND_SZ values arrive verbatim, so
    # %SystemRoot%-style entries must be expanded or they are inert.
    seen = set()
    entries = []
    for chunk in (os.environ.get("Path", ""), user.get("Path", ""), machine.get("Path", "")):
        for part in chunk.split(";"):
            part = os.path.expandvars(part).strip()
            if part and part.lower() not in seen:
                seen.add(part.lower())
                entries.append(part)
    os.environ["Path"] = ";".join(entries)

    for src in (machine, user):
        for k, v in src.items():
            if k.lower() == "path":
                continue
            os.environ.setdefault(k, os.path.expandvars(v) if isinstance(v, str) else v)


def locate_vs_install():
    vswhere = (
        Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"))
        / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
    )
    if not vswhere.exists():
        return None
    try:
        # -requires: the newest VS install may lack the C++ workload while an
        # older one has it; without this vswhere hands back an unusable path.
        proc = subprocess.run(
            [str(vswhere), "-latest", "-products", "*",
             "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
             "-property", "installationPath"],
            capture_output=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        # TimeoutExpired is a SubprocessError, not an OSError - catching only
        # OSError turned a timeout into a traceback instead of the actionable
        # "could not establish an MSVC environment" hint.
        return None
    text = decode_bytes(proc.stdout).strip().splitlines()
    return Path(text[0]) if text else None


def ensure_msvc_env():
    """Ensure INCLUDE/LIB/PATH carry the MSVC + clang-cl toolchain (runbook S3).
    No-op off Windows."""
    if host_os() != "windows":
        return True
    if os.environ.get("INCLUDE") and os.environ.get("LIB"):
        # Any non-empty INCLUDE/LIB pair used to pass - including an x86 or
        # ARM64 Native Tools prompt, which only fails much later as an lld-link
        # machine-type mismatch against the x64 vulkan-1.lib. The preset pins no
        # architecture, so the ambient environment is the only thing deciding it.
        return arch_is_x64()

    vs_install = locate_vs_install()
    if vs_install is None:
        return False
    vcvars = vs_install / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
    if not vcvars.exists():
        return False

    try:
        # shell=True is required here: cmd.exe's own /c argument parsing does
        # not compose with Python's argv-list quoting when the batch path
        # contains spaces (e.g. "Program Files (x86)"), so the whole
        # "call vcvars && set" line is handed to the shell as one string.
        proc = subprocess.run(f'"{vcvars}" && set', shell=True, capture_output=True, timeout=180)
    except (OSError, subprocess.SubprocessError):
        return False
    if proc.returncode != 0:
        return False

    env = {}
    for line in decode_bytes(proc.stdout).splitlines():
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        if k and not k.startswith("*"):
            env[k] = v
    if "INCLUDE" not in env or "LIB" not in env:
        return False
    os.environ.update(env)
    return arch_is_x64()


def arch_is_x64():
    """vcvars64/the Native Tools prompt records its target arch here."""
    arch = os.environ.get("VSCMD_ARG_TGT_ARCH")
    if arch is None:
        warn("VSCMD_ARG_TGT_ARCH is unset - cannot confirm the MSVC toolchain targets x64.")
        return True
    if arch.lower() != "x64":
        print(f"    [warn] MSVC environment targets {arch}, not x64.")
        return False
    return True


# --------------------------------------------------------------------------
# Subprocess helper (build_windows.py:200)
# --------------------------------------------------------------------------
CMD_METACHARACTERS = set("&|<>^%\"")


def run_checked(exe, args, cwd, what, hints=None):
    args = [str(a) for a in args]
    step(f"{exe} {' '.join(args)}")
    # Windows CreateProcess() cannot exec a .BAT/.CMD directly (flutter ships
    # as flutter.bat); it needs a command interpreter. Resolve the real path so
    # the decision is based on what is on disk, not the bare name, then route
    # batch files through shell=True. With shell=True, Popen still accepts an
    # argv list and quotes it itself (subprocess.list2cmdline), which avoids
    # hand-building a quoted command string (that trap is documented in the
    # Windows handover's "do not repeat" table).
    resolved = shutil.which(exe) or exe
    use_shell = resolved.lower().endswith((".bat", ".cmd"))
    if use_shell:
        # list2cmdline implements CommandLineToArgvW quoting, NOT cmd.exe
        # quoting: `%PATH%` passes through unquoted and a metacharacter in an
        # unspaced token is not escaped, so a user-supplied path could inject a
        # command. No current call site can carry one, and this keeps it that way.
        # ponytail: refuse rather than escape. Upgrade path: caret-escape the
        # metacharacters if a legitimate argument ever needs one.
        for a in args:
            if CMD_METACHARACTERS & set(a):
                fail(
                    f"refusing to pass {a!r} to the batch file {resolved}: it contains a cmd.exe "
                    "metacharacter (& | < > ^ % \").",
                    hints=["Move or rename the offending path so it has no shell metacharacters."],
                )
    proc = subprocess.Popen(
        [resolved, *args],
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,  # a child prompt must not silently block the build
        bufsize=1,                 # real line buffering: only legal in text mode
        text=True,
        encoding="utf-8",
        errors="replace",
        shell=use_shell,
    )
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
    proc.wait()
    if proc.returncode != 0:
        fail(
            f"{what} failed (exit code {proc.returncode}).",
            hints=hints or [
                "Fix the reported compiler/linker/tool error before re-running.",
                "Re-running is safe for a matching build tree; if the CMake/Flutter cache "
                "predates a target rename or a moved source dir, re-run with --clean.",
            ],
        )
    ok(what)


# --------------------------------------------------------------------------
# Phase 0: checks
# --------------------------------------------------------------------------
def cmake_version_ok(cmake_exe):
    """Returns a 3-tuple, or None if the version could not be established.
    None must be treated as a failure: it means the >=3.14 gate did not run."""
    try:
        proc = subprocess.run([cmake_exe, "--version"], capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    out = decode_bytes(proc.stdout)
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", out) or re.search(r"(\d+)\.(\d+)", out)
    if not m:
        return None
    parts = [int(g) for g in m.groups()]
    while len(parts) < 3:
        parts.append(0)  # so the comparison against (3, 14, 0) means what it looks like
    return tuple(parts)


def preset_names(presets_file):
    """Preset names from the JSON, not a substring match on the raw text (which
    would also match a configurePreset back-reference or a description)."""
    try:
        data = json.loads(presets_file.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError) as e:
        return None, f"could not parse {presets_file}: {e}"
    names = set()
    for key in ("configurePresets", "buildPresets", "testPresets"):
        for entry in data.get(key, []) or []:
            if isinstance(entry, dict) and "name" in entry:
                names.add(entry["name"])
    return names, None


def vulkan_api_version(vulkaninfo_exe):
    """Actually run vulkaninfo and read apiVersion, instead of reporting that
    it exists and telling the user to run it themselves."""
    try:
        proc = subprocess.run([vulkaninfo_exe, "--summary"], capture_output=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    out = decode_bytes(proc.stdout) + decode_bytes(proc.stderr)
    m = re.search(r"apiVersion\s*[:=]\s*[^\d]*(\d+)\.(\d+)\.(\d+)", out)
    if not m:
        return None
    return tuple(int(g) for g in m.groups())


def check_native(target, layout, problems):
    """Tool checks for a native dng_decoder_native build (runbook S1/S3)."""
    spec = NATIVE_SPECS[target]

    if not layout.native.exists():
        problems.append(
            f"native project not found at {layout.native} - the ceyx "
            "checkout must sit beside the Halcyon checkout."
        )
        return

    # Validate the destination instead of fabricating it later with mkdir: a
    # wrong or stale decoder tree otherwise receives the library in a folder
    # CMake never reads, and the only symptom is a Phase 3 "not bundled"
    # diagnostic that points at everything except the real cause.
    dest_parent = (layout.decoder / spec["dest"]).parent
    if not dest_parent.exists():
        problems.append(
            f"{dest_parent} does not exist - this decoder checkout has no "
            f"{spec['dest'].parts[1]} plugin folder, so the built library would be placed "
            "where nothing reads it."
        )

    presets = layout.native / "CMakePresets.json"
    if not presets.exists():
        problems.append(f"CMakePresets.json not found at {presets}")
    else:
        names, err = preset_names(presets)
        if err:
            problems.append(err)
        else:
            for name in (spec["stage1_preset"], spec["preset"]):
                if name and name not in names:
                    problems.append(
                        f"CMake preset {name} is missing from {presets} - do not hand-invent "
                        "a preset (runbook S3); report that the work item has not landed."
                    )
                elif name:
                    ok(f"CMake preset {name} present")

    cmake_exe = which("cmake")
    if not cmake_exe:
        problems.append("cmake not found on PATH (3.14 or newer required).")
    else:
        ver = cmake_version_ok(cmake_exe)
        if ver is None:
            problems.append(
                f"could not establish the CMake version from {cmake_exe} - the >=3.14 gate "
                "did not run, so the build must not proceed."
            )
        elif ver < (3, 14, 0):
            problems.append(f"CMake {'.'.join(map(str, ver))} is older than the required 3.14 (runbook S1).")
        else:
            ok(f"cmake: {'.'.join(map(str, ver))} ({cmake_exe})")

    if target == "windows":
        if not ensure_msvc_env():
            problems.append(
                "could not establish an MSVC environment (INCLUDE/LIB). Start an "
                '"x64 Native Tools Command Prompt for VS 2022", or install the VS '
                "Build Tools C++ workload so vswhere/vcvars64.bat can be found."
            )
        else:
            ok("MSVC environment (INCLUDE/LIB) present")

        clang_cl = which("clang-cl")
        if not clang_cl:
            problems.append(
                "clang-cl not found on PATH. Install the \"C++ Clang tools for Windows\" "
                "component or standalone LLVM. Runbook S1: cl.exe is NOT sufficient - the "
                "byte-exact colour contract needs -ffp-contract=off."
            )
        else:
            ok(f"clang-cl: {clang_cl}")

        ninja_exe = which("ninja")
        if not ninja_exe:
            problems.append(
                "ninja not found on PATH (the windows-vulkan preset uses the Ninja generator)."
            )
        else:
            ok(f"ninja: {ninja_exe}")

        if not os.environ.get("VULKAN_SDK"):
            problems.append("VULKAN_SDK is not set - install the LunarG Vulkan SDK.")
        else:
            vulkan_lib = Path(os.environ["VULKAN_SDK"]) / "Lib" / "vulkan-1.lib"
            if not vulkan_lib.exists():
                problems.append(f"vulkan-1.lib not found at {vulkan_lib}")
            else:
                ok(f"Vulkan SDK: {os.environ['VULKAN_SDK']}")

        vulkaninfo_exe = which("vulkaninfo")
        if not vulkaninfo_exe:
            warn("vulkaninfo not on PATH - cannot pre-check GPU/driver Vulkan 1.1+ support.")
        else:
            api = vulkan_api_version(vulkaninfo_exe)
            if api is None:
                warn(f"{vulkaninfo_exe} ran but no apiVersion could be parsed - Vulkan 1.1+ unconfirmed.")
            elif api < (1, 1, 0):
                problems.append(
                    f"the Vulkan driver reports apiVersion {'.'.join(map(str, api))}; the decoder "
                    "needs 1.1+ with vk_int8/vk_int16/vk_int64 (findings R5). Decode would fail at "
                    "runtime even if the build succeeds."
                )
            else:
                ok(f"Vulkan apiVersion {'.'.join(map(str, api))}")

        nasm_exe = which("nasm")
        if not nasm_exe:
            warn(
                "nasm not found - libjpeg-turbo will build with WITH_SIMD=OFF. Whether the SIMD "
                "and C decode paths are bit-identical for this pipeline's colour conversions is "
                "UNVERIFIED, so this may cause cross-platform output divergence, not just slower "
                "decoding."
            )
            for guess in (r"C:\Program Files\NASM", r"C:\Program Files (x86)\NASM"):
                if Path(guess, "nasm.exe").exists():
                    step(f"nasm IS installed at {guess} but is not on PATH - add that folder and re-run.")
                    break
        else:
            ok(f"nasm: {nasm_exe}")

    if target == "android":
        if not which("ninja"):
            problems.append("ninja not found on PATH (the android-vulkan preset uses Ninja).")
        ndk = os.environ.get("ANDROID_NDK_HOME")
        if not ndk or not Path(ndk).exists():
            problems.append(
                "ANDROID_NDK_HOME is not set to an existing NDK - the android-vulkan preset's "
                "toolchainFile resolves through it."
            )
        else:
            ok(f"ANDROID_NDK_HOME: {ndk}")

    if target == "macos":
        if not which("xcodebuild"):
            problems.append("xcodebuild not found - install Xcode / the command line tools.")


def check_heif_dist(target, layout, problems):
    """Phase 0 readiness for the HEIC route (spec section 7.3).

    A missing dist is a PROBLEM, not a warning: cmake/heif.cmake fails the
    configure with the same message, and discovering it at Phase 0 costs
    seconds instead of a full Halide-backed configure.
    """
    dist = layout.native / "third_party" / "heif-dist"
    provenance = dist / "PROVENANCE.md"
    if not provenance.exists():
        problems.append(
            f"{provenance} not found - the HEIC route needs the vendored "
            "libheif/libde265 distribution. Run "
            "ceyx/native/scripts/fetch_heif_deps.sh, or configure the native "
            "build with -DDNG_ENABLE_HEIF=OFF to build without HEIC."
        )
        return

    libs = HEIF_RUNTIME_LIBS.get(target, [])
    missing = [name for name in libs if not (dist / "lib" / name).exists()]
    if missing:
        problems.append(
            f"HEIF dist at {dist} is missing {', '.join(missing)} - re-run "
            "ceyx/native/scripts/fetch_heif_deps.sh."
        )
        return

    suffix = "" if target in HEIF_VERIFIED_TARGETS else \
        " [unverified (phase 2 scope: macOS)]"
    for name in libs:
        ok(f"libheif/libde265 dist: {name}{suffix}")


def check_symlink_support(problems):
    """Flutter on Windows needs symlink support (Developer Mode). Without it
    Phase 2 dies deep inside the tool; the changes doc records this costing a
    whole session before the user enabled Developer Mode by hand."""
    try:
        with tempfile.TemporaryDirectory(prefix="halcyon_symlink_") as tmp:
            target = Path(tmp) / "t"
            target.mkdir()
            os.symlink(target, Path(tmp) / "l", target_is_directory=True)
    except OSError as e:
        problems.append(
            f"this account cannot create symlinks ({e}) - `flutter build windows` requires them. "
            "Enable Windows Developer Mode (Settings > Privacy & security > For developers) and "
            "re-run."
        )
        return
    ok("symlink support present (Developer Mode)")


def stale_cmake_target(target, layout, args):
    """S7: CMake does not update a cached $<TARGET_FILE_DIR:...> when the target
    is renamed, so a build/ tree from before the photo_selector_flutter ->
    halcyon rename fails with `No target "photo_selector_flutter"`. Detect it
    and name it, instead of telling the user to just re-run."""
    if target != "windows" or args.clean:
        return None
    build_dir = layout.halcyon / "build" / "windows"
    if not build_dir.exists():
        return None
    for cache in build_dir.rglob("CMakeCache.txt"):
        try:
            text = cache.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "photo_selector_flutter" in text:
            return (
                f"{cache} was configured for the old target name photo_selector_flutter. CMake "
                "cannot rename a cached target in place; the build would fail with "
                '`No target "photo_selector_flutter"`. Re-run with --clean.'
            )
    return None


def check_target(target, layout, args, native_due):
    """Phase 0. Collects every problem, then fails once with all of them."""
    problems = []

    if not supports_target(target):
        fail(
            f"'{target}' cannot be built on this host ({host_os()}).",
            hints=[
                "windows builds on Windows, linux on Linux, macos/ios on macOS.",
                "Use `all` to build everything this host supports.",
            ],
        )

    if args.skip_flutter_build:
        if not (which("flutter") or which("flutter.bat")):
            warn("flutter not on PATH - fine, --skip-flutter-build was requested.")
    else:
        flutter_exe = which("flutter") or which("flutter.bat")
        if not flutter_exe:
            problems.append("Flutter is not available in PATH.")
        else:
            ok(f"flutter: {flutter_exe}")

    if not (layout.decoder / "plugin" / "pubspec.yaml").exists():
        problems.append(
            f"the ceyx package was not found under {layout.decoder} - "
            "pubspec.yaml depends on it by relative path, so `flutter pub get` will fail."
        )
    else:
        ok(f"decoder package: {layout.decoder}")

    if target in ("android", "android-apk", "android-aab"):
        configure_android_java()
        if not which("java"):
            problems.append("no java on PATH after JDK selection - Gradle cannot run.")

    if target == "windows" and not args.skip_flutter_build:
        check_symlink_support(problems)

    stale = stale_cmake_target(target, layout, args)
    if stale:
        problems.append(stale)

    if native_due:
        check_native(native_target_for(target), layout, problems)

    if native_due and native_target_for(target) is not None:
        check_heif_dist(native_target_for(target), layout, problems)

    if args.cfa_sample_dng and not Path(args.cfa_sample_dng).exists():
        problems.append(f"--cfa-sample-dng file not found: {args.cfa_sample_dng}")
    if native_due and not args.cfa_sample_dng and not args.no_colour_gate:
        # B1: build_windows.py warned and shipped the library anyway, under a
        # green exit code. Runbook S4 orders the gate BEFORE placement.
        problems.append(
            "a native build is due but no --cfa-sample-dng was given, so the runbook S4 colour "
            "gate (blue-sky B >> R) cannot run. Pass a sample, or pass --no-colour-gate to "
            "acknowledge shipping an unvalidated library (that run then exits non-zero)."
        )

    if problems:
        fail(
            f"{len(problems)} prerequisite problem(s) for target '{target}':",
            hints=problems,
        )
    ok(f"host {host_os()}/{host_arch()} can build '{target}'")


# --------------------------------------------------------------------------
# Phase 0b: Halide v21 distribution
# --------------------------------------------------------------------------
def halide_asset():
    key = (host_os(), host_arch())
    if key not in HALIDE_PLATFORMS:
        fail(f"no Halide v{HALIDE_VERSION} distribution is published for {key[0]}/{key[1]}.")
    plat, ext = HALIDE_PLATFORMS[key]
    name = f"Halide-{HALIDE_VERSION}-{plat}-{HALIDE_COMMIT}.{ext}"
    url = f"https://github.com/halide/Halide/releases/download/v{HALIDE_VERSION}/{name}"
    return name, url, ext, HALIDE_SHA256.get(plat)


def download_with_progress(url, dest):
    step(f"downloading {os.path.basename(dest)}")
    step(f"from {url}")

    def _report(block_num, block_size, total_size):
        if total_size <= 0:
            return
        downloaded = block_num * block_size
        pct = min(100, downloaded * 100 // total_size)
        if block_num % 200 == 0 or downloaded >= total_size:
            step(f"  {pct}% ({downloaded // (1024 * 1024)} MiB / {total_size // (1024 * 1024)} MiB)")

    # A stalled connection used to hang forever with no output, because the
    # progress reporter only prints every 200 blocks.
    old_timeout = socket.getdefaulttimeout()
    socket.setdefaulttimeout(60)
    try:
        urllib.request.urlretrieve(url, dest, reporthook=_report)
    except Exception as e:  # noqa: BLE001 - surfaced via fail()
        fail(
            f"download of {os.path.basename(dest)} failed: {e}",
            hints=[
                f"Download it manually from {url}",
                "Extract it so that <native>/third_party/halide/lib/ holds Halide.lib "
                "(Windows) or libHalide.a (POSIX), then re-run.",
            ],
        )
    finally:
        socket.setdefaulttimeout(old_timeout)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _skip_doc(name):
    # Doxygen HTML under share/doc/ has MAX_PATH-busting filenames on Windows
    # and is not needed by the build.
    return "/share/doc/" in name.replace("\\", "/").lower()


def extract_archive(archive, ext, stage_dir):
    skipped = 0
    try:
        if ext == "zip":
            # zipfile.extract sanitises traversal, so no zip-slip guard is needed.
            with zipfile.ZipFile(archive) as zf:
                for name in zf.namelist():
                    if _skip_doc(name):
                        skipped += 1
                        continue
                    zf.extract(name, stage_dir)
        else:
            with tarfile.open(archive, "r:gz") as tf:
                for member in tf.getmembers():
                    if _skip_doc(member.name):
                        skipped += 1
                        continue
                    tf.extract(member, stage_dir)
    except (zipfile.BadZipFile, tarfile.TarError, OSError, EOFError) as e:
        # A truncated-but-complete-looking archive used to escape as a traceback.
        fail(
            f"{archive} could not be extracted: {e}",
            hints=["Delete the partial download and re-run; the archive is corrupt."],
        )
    if skipped:
        step(f"skipped {skipped} doc entries under share/doc/ (not needed for the build)")


def halide_present(halide_dir):
    return (halide_dir / "lib" / "Halide.lib").exists() or (halide_dir / "lib" / "libHalide.a").exists()


def ensure_halide(native_dir, expected_sha256=None):
    halide_dir = native_dir / "third_party" / "halide"
    asset, url, ext, pinned = halide_asset()
    expected_sha256 = expected_sha256 or pinned

    if halide_present(halide_dir):
        # The VERSION stamp this script writes is now read back: a leftover
        # Halide from another version/platform has a lib/ that satisfies the
        # existence check and would otherwise be accepted silently.
        stamp = halide_dir / "VERSION"
        stamped = stamp.read_text(encoding="utf-8", errors="replace") if stamp.exists() else ""
        if f"asset: {asset}" in stamped:
            ok(f"already present: {halide_dir} ({asset})")
        elif not stamped:
            warn(f"{halide_dir} has no VERSION stamp - cannot confirm it is {asset}. Using it as-is.")
        else:
            fail(
                f"{halide_dir} holds a different Halide distribution than this build expects.",
                hints=[
                    f"expected asset: {asset}",
                    "found: " + " / ".join(l for l in stamped.splitlines() if l.startswith("asset:")),
                    f"Delete {halide_dir} and re-run to fetch the pinned distribution.",
                ],
            )
        return

    with tempfile.TemporaryDirectory(prefix="halide21_") as tmp:
        tmp = Path(tmp)
        archive = tmp / asset
        download_with_progress(url, str(archive))

        # Verified after download and BEFORE extraction: a substituted archive
        # must never reach the extractor.
        observed = sha256_of(archive)
        if expected_sha256:
            if observed.lower() != expected_sha256.lower():
                # Quarantine rather than leave it where a later run could adopt it.
                quarantine = archive.with_suffix(archive.suffix + ".REJECTED")
                try:
                    archive.rename(quarantine)
                except OSError:
                    quarantine = archive
                fail(
                    f"{asset} sha256 MISMATCH - refusing to extract it.",
                    hints=[
                        f"expected: {expected_sha256}",
                        f"observed: {observed}",
                        f"quarantined at: {quarantine} (deleted with the temp dir on exit)",
                        "The release asset was replaced, or the download is corrupt. Do not "
                        "build with it. Re-run; if it mismatches again, the asset changed "
                        "upstream and HALIDE_SHA256 must be re-derived deliberately.",
                    ],
                )
            ok(f"sha256 verified: {observed}")
        else:
            # ponytail: reachable only on a host/arch with no pinned digest.
            # Upgrade path: add the digest to HALIDE_SHA256 from the release API.
            warn(f"no pinned sha256 for {asset} - integrity UNVERIFIED. observed: {observed}")

        stage_dir = tmp / "x"
        stage_dir.mkdir(parents=True, exist_ok=True)
        extract_archive(archive, ext, stage_dir)

        tops = [p for p in stage_dir.iterdir() if p.is_dir()]
        if len(tops) != 1:
            fail(
                f"unexpected archive layout in {asset}: {len(tops)} top-level folders "
                f"({[p.name for p in tops]}) - expected exactly one."
            )
        top = tops[0]

        halide_dir.mkdir(parents=True, exist_ok=True)
        for item in top.iterdir():
            dest = halide_dir / item.name
            if item.is_dir():
                shutil.copytree(item, dest, dirs_exist_ok=True)
            else:
                shutil.copy2(item, dest)

        # The v21.0.0 Windows asset nests the .lib under lib\Release\
        # (multi-config layout); find_package(Halide) expects lib\Halide.lib.
        nested_lib = halide_dir / "lib" / "Release" / "Halide.lib"
        flat_lib = halide_dir / "lib" / "Halide.lib"
        if nested_lib.exists() and not flat_lib.exists():
            step(f"mirroring {nested_lib} -> {flat_lib}")
            shutil.copy2(nested_lib, flat_lib)

        if not halide_present(halide_dir):
            fail(f"Halide extraction finished but no Halide library is present under {halide_dir}/lib.")

        (halide_dir / "VERSION").write_text(
            f"halide/Halide@v{HALIDE_VERSION}\n"
            f"binary_provenance: vendored from "
            f"https://github.com/halide/Halide/releases/tag/v{HALIDE_VERSION}\n"
            f"asset: {asset}\n"
            f"sha256: {observed}\n"
            "abi_notes: schedule changes break AOT artifacts; bump requires full regen.\n",
            encoding="ascii",
        )
    ok(f"installed: {halide_dir}")


# --------------------------------------------------------------------------
# Phase 1: native build
# --------------------------------------------------------------------------
def native_target_for(target):
    """Which NATIVE_SPECS entry a Flutter target needs (None if it has none)."""
    if target in ("android", "android-apk", "android-aab"):
        return "android" if "android" in NATIVE_SPECS else None
    return target if target in NATIVE_SPECS else None


def native_is_due(target, layout, mode):
    """`--native auto|always|never` collapsed into one yes/no answer.

    auto = build only when the prebuilt library the Flutter build will consume
    is missing. That is why a macOS build is fast (the dylib is committed) and
    a fresh Windows build is not (only a .gitkeep is committed there)."""
    nt = native_target_for(target)
    if nt is None:
        if mode == "always":
            fail(f"--native always was requested but '{target}' has no native decoder library.")
        return False
    if mode == "never":
        return False
    if mode == "always":
        return True
    dest = layout.decoder / NATIVE_SPECS[nt]["dest"] / NATIVE_SPECS[nt]["artifact"]
    return not dest.exists()


def build_native(target, layout, args):
    nt = native_target_for(target)
    if nt is None:
        fail(f"'{target}' has no native decoder library to build.")
    spec = NATIVE_SPECS[nt]
    native_dir = layout.native

    phase(f"Phase 0b: Halide v{HALIDE_VERSION} distribution")
    ensure_halide(native_dir, args.halide_sha256)

    phase(f"Phase 1: native dng_decoder_native ({spec['preset']})")

    if spec["stage1_preset"]:
        # Android needs host generators before the cross build (Stage 1/2).
        run_checked("cmake", ["--preset", spec["stage1_preset"]], native_dir,
                    f"cmake configure ({spec['stage1_preset']})")
        run_checked("cmake", ["--build", "--preset", spec["stage1_preset"]], native_dir,
                    f"cmake build ({spec['stage1_preset']})")

    run_checked("cmake", ["--preset", spec["preset"]], native_dir,
                f"cmake configure ({spec['preset']})")

    if args.native_target:
        names = " ".join(args.native_target)
        run_checked("cmake", ["--build", "--preset", spec["preset"], "--target", *args.native_target],
                    native_dir, f"cmake build ({names})")
        ok(f"--native-target {names} built; stopping before library placement.")
        return None

    run_checked("cmake", ["--build", "--preset", spec["preset"], "--target", "dng_decoder_native"],
                native_dir, "cmake build (dng_decoder_native)")

    build_dir = native_dir / spec["build_dir"]
    built = build_dir / spec["artifact"]
    if not built.exists():
        fail(
            f"the build succeeded but {built} does not exist.",
            hints=[
                f"The preset is expected to write exactly {spec['artifact']} into {build_dir}.",
                "Check the build output above for where the shared library was actually written.",
            ],
        )
    ok(f"built: {built}")

    if args.cfa_sample_dng:
        # runbook S4 colour gate: blue-sky B >> R, before the library is trusted.
        run_checked("cmake", ["--build", "--preset", spec["preset"], "--target", "test_cfa_color"],
                    native_dir, "cmake build (test_cfa_color)")
        exe_name = "test_cfa_color.exe" if host_os() == "windows" else "test_cfa_color"
        cfa_exe = build_dir / exe_name
        if not cfa_exe.exists():
            fail(f"{exe_name} not found at {cfa_exe}")
        run_checked(str(cfa_exe), [args.cfa_sample_dng, "--expect-blue-sky"], build_dir,
                    "test_cfa_color colour gate")
    else:
        # Reachable only via --no-colour-gate (Phase 0 blocks it otherwise).
        # The library is still placed so the rest of the pipeline can be
        # exercised, but the run is marked ungated and finish() exits 2.
        global COLOUR_GATE_SKIPPED
        COLOUR_GATE_SKIPPED = True
        warn("colour gate SKIPPED by --no-colour-gate: this library is unvalidated.")
        step("Runbook S4 requires test_cfa_color (blue-sky B >> R) to pass before the library is")
        step("trusted. Do not commit or ship the artifact from this run without running that gate.")

    # H1 known-answer colour gate (spec section 7.5). S4 validates the RAW
    # demosaic/colour pipeline from a Bayer sample and shares no code with
    # HEIC's YUV -> RGB conversion, so extending --cfa-sample-dng to HEIC
    # would be theatre; HEIC needs its OWN reference comparison, in the same
    # Phase 1 position, failing the build the same way.
    #
    # There is deliberately no --no-h1-gate: the fixtures are committed, so
    # unlike S4 there is no "the user did not supply a sample" case to opt out
    # of. A disabled HEIF route is the only skip, and it prints a line.
    heif_sample = native_dir / "tests" / "data" / "h1_sample.heic"
    heif_reference = native_dir / "tests" / "data" / "h1_reference.rgba"
    if not heif_sample.exists() or not heif_reference.exists():
        fail(
            "the H1 HEIC colour-gate fixtures are missing.",
            hints=[
                f"expected {heif_sample} and {heif_reference}",
                "Regenerate with ceyx/native/tests/data/make_h1_fixtures.sh, or "
                "configure the native build with -DDNG_ENABLE_HEIF=OFF if this "
                "target has no HEIC route.",
            ],
        )
    run_checked("cmake", ["--build", "--preset", spec["preset"], "--target", "test_heif_color"],
                native_dir, "cmake build (test_heif_color)")
    h1_exe_name = "test_heif_color.exe" if host_os() == "windows" else "test_heif_color"
    h1_exe = build_dir / h1_exe_name
    if not h1_exe.exists():
        fail(f"{h1_exe_name} not found at {h1_exe}")
    run_checked(str(h1_exe), [str(heif_sample), str(heif_reference)], build_dir,
                "test_heif_color H1 colour gate")

    dest_dir = layout.decoder / spec["dest"]
    if not dest_dir.exists():
        dest_dir.mkdir(parents=True, exist_ok=True)
    placed = dest_dir / spec["artifact"]
    shutil.copy2(built, placed)
    if not placed.exists():
        fail(f"copy to {dest_dir} did not produce {spec['artifact']}")
    ok(f"placed: {placed}")
    if nt == "macos":
        # macOS's CMake POST_BUILD step (native/cmake/pipeline.cmake) vendors
        # any Homebrew-path deps next to the built dylib so the bundle is
        # self-contained -- carry those sibling .dylib files along too.
        for sibling in build_dir.glob("*.dylib"):
            if sibling.name == spec["artifact"]:
                continue
            shutil.copy2(sibling, dest_dir / sibling.name)
            ok(f"placed: {dest_dir / sibling.name}")
    if layout.packaged:
        step("This extracted tree is not a git checkout, so the runbook S4 git commit step")
        step("cannot run here. Copy the library back into the ceyx repo and")
        step("commit it there.")
    return placed


# --------------------------------------------------------------------------
# Phase 2/3: Flutter build + artifact verification
# --------------------------------------------------------------------------
def git_build_commit(halcyon):
    """The commit this build's `lib/` came from, for the P-2 in-app version
    stamp (lib/perf/perf_log.dart's `kHalcyonBuildCommit`, injected below via
    --dart-define). Degrades to the literal string "unknown" on ANY failure
    (git missing, not a checkout, a timeout) rather than a plausible-looking
    wrong hash -- the whole point of the stamp is that a reader can trust it,
    so silence here would be worse than no stamp at all. A dirty working
    tree gets a distinguishable "<hash>-dirty" suffix: a hash claiming to be
    a clean commit while the tree had uncommitted changes is exactly the
    kind of confident-but-wrong provenance P-2 exists to prevent.
    """
    try:
        rev = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=str(halcyon), capture_output=True, timeout=15, text=True,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    if rev.returncode != 0:
        return "unknown"
    commit = rev.stdout.strip()
    if not commit:
        return "unknown"
    try:
        status = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=str(halcyon), capture_output=True, timeout=15, text=True,
        )
    except (OSError, subprocess.SubprocessError):
        # Commit hash is real; dirty-or-not is merely unknown. Report the
        # hash rather than throwing away a fact we do have.
        return commit
    if status.returncode == 0 and status.stdout.strip():
        return f"{commit}-dirty"
    return commit


def macos_config_name(mode):
    return {"debug": "Debug", "profile": "Profile", "release": "Release"}[mode]


def flutter_artifact(target, mode, halcyon):
    """Where the artifact really is, plus a human label. build.sh printed a
    hard-coded macOS bundle name; this resolves it instead."""
    b = halcyon / "build"
    if target == "macos":
        d = b / "macos" / "Build" / "Products" / macos_config_name(mode)
        apps = sorted(d.glob("*.app"))
        return (apps[0] if apps else d), "macOS app bundle"
    if target == "ios":
        return b / "ios" / "iphoneos", "iOS build products"
    if target in ("android", "android-apk"):
        return b / "app" / "outputs" / "flutter-apk", "APK output folder"
    if target == "android-aab":
        return b / "app" / "outputs" / "bundle", "App Bundle output folder"
    if target == "web":
        return b / "web", "web output folder"
    if target == "windows":
        return b / "windows" / "x64" / "runner" / macos_config_name(mode), "Windows runner folder"
    if target == "linux":
        # build/linux/<arch>/<mode>/bundle - the arch segment is host-dependent.
        bundles = sorted((b / "linux").glob(f"*/{mode}/bundle"))
        return (bundles[0] if bundles else b / "linux"), "Linux bundle"
    return b, "build folder"


def verify_windows_bundle(release_dir, halcyon, placed_dll):
    """runbook S5: the DLL must sit next to the exe. Never copy it by hand -
    that hides a real packaging bug."""
    bundled = release_dir / "dng_decoder_native.dll"
    if bundled.exists():
        ok(f"bundled: {bundled}")
    else:
        print()
        print("    Packaging check FAILED - running the runbook S5 diagnostics:")
        gen_plugins = halcyon / "windows" / "flutter" / "generated_plugins.cmake"
        if gen_plugins.exists():
            gen_text = gen_plugins.read_text(encoding="utf-8", errors="replace")
            if "ceyx" in gen_text:
                print("    1. generated_plugins.cmake DOES list ceyx (plugin discovered).")
            else:
                print("    1. generated_plugins.cmake does NOT list ceyx.")
                print("       -> flutter pub get did not pick up the plugin declaration (W10).")
                print("       -> try: flutter clean, then re-run this script (stale generated files).")
        else:
            print(f"    1. {gen_plugins} is missing entirely.")
        print(f"    2. Check that {placed_dll} existed at configure time (a stale CMake cache from")
        print("       before Phase 1 can still hold the empty value). Try: flutter clean, re-run.")
        print("       Then grep the CMake log for ceyx_bundled_libraries; if it")
        print("       resolves to empty, that is the silent-failure mode documented in")
        print("       plugin/windows/CMakeLists.txt.")
        fail(
            f"dng_decoder_native.dll is not in {release_dir}",
            hints=["Runbook S5: do not manually copy the DLL as a workaround - it would hide a real bug."],
        )

    exes = list(release_dir.glob("*.exe"))
    if not exes:
        warn(f"no .exe found in {release_dir} - the DLL is there but the runner is not.")
    else:
        for exe in exes:
            ok(f"runner exe alongside it: {exe.name}")


def print_windows_protocol(release_dir):
    phase("Phase 3: manual verification (this script does not automate it)")
    print()
    print("    Runbook S5 - correctness:")
    print(f"      1. Launch {release_dir}\\halcyon.exe")
    print("      2. Open DNG files from local_data\\photo_samples\\DNG\\ ONLY.")
    print("      3. Confirm DngResult.errorCode == 0 for each sample.")
    print("      4. Confirm there is no RAW_UNSUPPORTED / MISSING_PLUGIN fallback to the Dart")
    print("         preview path - a silent fallback looks like success while native decode failed.")
    print()
    print("    Runbook S6 - timing (the 1-second gate):")
    print("      1. Pick 3-5 representative DNG samples.")
    print("      2. COLD-LAUNCH the exe for every \"first decode\" measurement (fresh process).")
    print("      3. Record wall-clock \"decode requested\" -> \"decode complete\" (decodeMs + processMs).")
    print("      4. HARD GATE: if any first decode exceeds 1000 ms, STOP. Do not average it away,")
    print("         do not retry until fast, do not report a warm number. Record: exact ms, which")
    print("         sample, GPU model + driver version (vulkaninfo), and whether a second cold")
    print("         launch shows the same first-decode latency.")
    print("      5. Then, in the SAME warm process, decode 5-10 more samples; record min/median/max.")
    print("      6. If the gate is breached: write a handover document first (runbook S6).")
    print("      7. If the gate passes: record the numbers in runbook section 7 \"Results\".")


def lipo_slices(binary):
    """Architecture slices in a Mach-O file, or None if lipo could not say."""
    try:
        proc = subprocess.run(["lipo", "-info", str(binary)], capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    text = decode_bytes(proc.stdout).strip()
    tail = text.rsplit(":", 1)[-1] if ":" in text else text
    return set(tail.split()) or None


def verify_macos_slices(app_bundle, layout, args):
    """The app must not carry a slice the native decoder lacks: the linker only
    WARNS when it drops an incompatible dylib, so a universal app silently ships
    an Intel slice with no RAW decode at all (PL-6)."""
    binaries = sorted((app_bundle / "Contents" / "MacOS").glob("*"))
    exe = next((b for b in binaries if b.is_file() and os.access(b, os.X_OK)), None)
    if exe is None:
        warn(f"no executable found in {app_bundle}/Contents/MacOS - cannot check architectures.")
        return
    app_slices = lipo_slices(exe)
    if app_slices is None:
        warn(f"lipo could not report the architectures of {exe}.")
        return
    ok(f"app slices: {' '.join(sorted(app_slices))} ({exe.name})")

    if args.macos_arch != "universal" and app_slices != {args.macos_arch}:
        fail(
            f"expected an {args.macos_arch}-only app but {exe} has: {' '.join(sorted(app_slices))}",
            hints=[
                "FLUTTER_XCODE_ARCHS did not take effect - check the xcodebuild line above.",
                "Re-run with --clean if a previous universal build is cached.",
            ],
        )

    dylib = layout.decoder / NATIVE_SPECS["macos"]["dest"] / NATIVE_SPECS["macos"]["artifact"]
    if not dylib.exists():
        return
    lib_slices = lipo_slices(dylib)
    if lib_slices is None:
        return
    ok(f"decoder slices: {' '.join(sorted(lib_slices))}")
    missing = app_slices - lib_slices
    if missing:
        warn(
            f"the app has slice(s) {' '.join(sorted(missing))} that {dylib.name} does not - "
            "those slices link WITHOUT the native RAW decoder (ld only warns about this)."
        )


def verify_macos_heif_rpaths(app_bundle):
    """Mechanically prove spec section 7.2's DYNAMIC-linking decision shipped.

    Not a style check: static linking would trigger LGPL-3 section 4(d)(0)'s
    duty to ship relinkable object files with every release. `otool -L` naming
    both libraries via @rpath, and both files being present in Frameworks/, is
    the evidence that a user can replace them. Collected and reported once so a
    partial regression names every missing piece, not just the first.
    """
    problems = []
    frameworks = app_bundle / "Contents" / "Frameworks"
    decoder = frameworks / "libdng_decoder_native.dylib"
    if not decoder.exists():
        fail(f"{decoder} not bundled - the HEIC @rpath check cannot run.")
    for name in HEIF_RUNTIME_LIBS["macos"]:
        if not (frameworks / name).exists():
            problems.append(
                f"{name} is not in {frameworks} - the HEIC route would fail to "
                "load at runtime on any machine without a system libheif."
            )
    out = subprocess.run(["otool", "-L", str(decoder)],
                         capture_output=True, text=True, check=False).stdout
    for name in HEIF_RUNTIME_LIBS["macos"]:
        if f"@rpath/{name}" not in out:
            problems.append(
                f"{decoder} does not name @rpath/{name} - either HEIF was "
                "linked statically (which the LGPL-3 position forbids) or the "
                "install name was not set to @rpath."
            )
    if problems:
        fail("the shipped macOS bundle fails the HEIF @rpath verification.",
             hints=problems)
    ok("HEIF @rpath dependencies present in the app bundle "
       f"({', '.join(HEIF_RUNTIME_LIBS['macos'])})")


def build_flutter(target, layout, mode, args, placed_native):
    phase(f"Phase 2: flutter build {target} ({mode})")
    run_checked("flutter", ["pub", "get"], layout.halcyon, "flutter pub get")

    build_commit = git_build_commit(layout.halcyon)
    step(f"build commit stamp: {build_commit}")
    build_args = [
        "build", *FLUTTER_BUILD_ARGS[target], f"--{mode}",
        f"--dart-define=HALCYON_BUILD_COMMIT={build_commit}",
    ]
    if target == "ios" and not args.ios_codesign:
        # ponytail: unattended builds have no signing identity configured here.
        # Upgrade path: drop --no-codesign and pass --ios-codesign once an
        # export/signing configuration exists in ios/.
        build_args.append("--no-codesign")
    if target == "macos" and args.macos_arch != "universal":
        # flutter has no --arch flag for macOS; FLUTTER_XCODE_<SETTING> is the
        # supported passthrough and needs no edit under macos/.
        os.environ["FLUTTER_XCODE_ARCHS"] = args.macos_arch
        os.environ["FLUTTER_XCODE_ONLY_ACTIVE_ARCH"] = "NO"
        step(f"ARCHS={args.macos_arch} (via FLUTTER_XCODE_ARCHS)")
    run_checked("flutter", build_args, layout.halcyon, f"flutter build {target} --{mode}")

    phase("Phase 3: artifact verification")
    artifact, label = flutter_artifact(target, mode, layout.halcyon)
    if not artifact.exists():
        fail(
            f"flutter reported success but the expected {label} is missing: {artifact}",
            hints=["Check the flutter output above; the artifact layout may have changed."],
        )
    ok(f"{label}: {artifact}")

    if target == "macos":
        verify_macos_slices(artifact, layout, args)
        verify_macos_heif_rpaths(artifact)

    if target == "windows":
        expect_dll = (layout.decoder / NATIVE_SPECS["windows"]["dest"] /
                      NATIVE_SPECS["windows"]["artifact"])
        if placed_native or expect_dll.exists():
            verify_windows_bundle(artifact, layout.halcyon, placed_native or expect_dll)
            print_windows_protocol(artifact)
        else:
            warn(
                "no prebuilt dng_decoder_native.dll to bundle - the app will run without "
                "native RAW decode. Re-run with --native always to build it."
            )

        # M6 F-18: regenerate the file-association .reg from
        # SupportedPhotoFormats.supportedExtensions so it can't drift from the
        # app's actual supported set (scripts/gen_windows_associations.dart).
        run_checked(
            "dart",
            ["run", "scripts/gen_windows_associations.dart"],
            layout.halcyon,
            "generate windows/runner/halcyon_associations.reg",
        )


# --------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------
CLEANABLE = {
    "macos": Path("build") / "macos",
    "ios": Path("build") / "ios",
    "android": Path("build") / "app",
    "android-apk": Path("build") / "app",
    "android-aab": Path("build") / "app",
    "web": Path("build") / "web",
    "windows": Path("build") / "windows",
    "linux": Path("build") / "linux",
}


def clean_target(target, layout):
    """--clean: delete only this target's own build output. A CMake cache that
    predates a target rename cannot be updated in place, which is the one case
    where re-running without cleaning loops forever on the same error."""
    victim = layout.halcyon / CLEANABLE[target]
    if victim.exists():
        step(f"removing {victim}")
        shutil.rmtree(victim)
        ok(f"cleaned: {victim}")
    else:
        ok(f"nothing to clean: {victim} does not exist")


def build_target(target, layout, mode, args):
    log(f"Target: {target} ({mode})")

    if args.clean and not args.check:
        phase(f"Phase 0: clean ({target})")
        clean_target(target, layout)

    native_due = native_is_due(target, layout, args.native)
    phase(f"Phase 0: prerequisite checks ({target})")
    check_target(target, layout, args, native_due)
    if args.check:
        return

    placed_native = None
    if native_due:
        placed_native = build_native(target, layout, args)
        if args.native_target:
            return  # iteration aid: stop after the requested native targets
    else:
        nt = native_target_for(target)
        if nt:
            ok("native library already present - skipping the native build "
               "(pass --native always to force a rebuild).")

    if args.skip_flutter_build:
        phase("Phase 2: skipped (--skip-flutter-build)")
        return

    build_flutter(target, layout, mode, args, placed_native)


def build_all(layout, mode, args):
    for target in ALL_TARGETS:
        if supports_target(target):
            build_target(target, layout, mode, args)
        else:
            log(f"Skipping {target} build on {host_os()}")


def resolve_mode(args):
    mode = os.environ.get("BUILD_MODE", "release")
    if args.mode:
        mode = args.mode
    if mode not in ("debug", "profile", "release"):
        fail(f"unknown build mode '{mode}' (expected debug, profile or release).")
    return mode


def make_parser():
    epilog = ["Targets:"]
    for name, desc in TARGET_HELP:
        epilog.append(f"  {name:<12} {desc}")
    epilog += [
        "",
        "Examples:",
        "  python3 scripts/build_apps.py                       # macos, release",
        "  python3 scripts/build_apps.py web --debug",
        "  python3 scripts/build_apps.py all",
        "  python3 scripts/build_apps.py macos --check         # preflight only",
        "  python3 scripts/build_apps.py windows --native always --cfa-sample-dng sky.dng",
        "  python3 scripts/build_apps.py windows --clean",
        "  BUILD_MODE=debug python3 scripts/build_apps.py macos",
        "",
        "Exit codes:",
        "  0  success",
        "  1  a check, a build step or a verification failed",
        "  2  the build worked but the runbook S4 colour gate was skipped via",
        "     --no-colour-gate (or --strict was given and warnings were raised)",
        "",
        "Build outputs land under ./build/. The platform folders (macos/, android/,",
        "windows/, ...) are source/config, not build output.",
    ]
    p = argparse.ArgumentParser(
        prog="build_apps.py",
        description="Build Halcyon (native ceyx decoder + Flutter) for any supported target.",
        epilog="\n".join(epilog),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("target", nargs="?", default="macos", choices=TARGETS,
                   help="What to build (default: macos).")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--debug", dest="mode", action="store_const", const="debug",
                      help="Build in debug mode.")
    mode.add_argument("--profile", dest="mode", action="store_const", const="profile",
                      help="Build in profile mode.")
    mode.add_argument("--release", dest="mode", action="store_const", const="release",
                      help="Build in release mode (default; BUILD_MODE env also honoured).")
    p.add_argument("--check", action="store_true",
                   help="Run the Phase 0 host/tool checks only and exit non-zero if anything "
                        "required is missing. Builds nothing.")
    p.add_argument("--native", choices=["auto", "always", "never"], default="auto",
                   help="Native dng_decoder_native build: auto (default; build only when the "
                        "prebuilt library is missing), always, or never.")
    p.add_argument("--native-target", nargs="+", metavar="TARGET",
                   help="Configure, then build only these native CMake targets and stop "
                        "(iteration aid; skips library placement and the Flutter build).")
    p.add_argument("--skip-flutter-build", "--native-only", dest="skip_flutter_build",
                   action="store_true", help="Run the native phases only.")
    p.add_argument("--cfa-sample-dng", default="",
                   help="Blue-sky DNG sample for the runbook S4 colour gate. Required whenever a "
                        "native build runs, unless --no-colour-gate is given.")
    p.add_argument("--no-colour-gate", action="store_true",
                   help="Acknowledge building and placing the native library WITHOUT the runbook "
                        "S4 colour gate. The run then exits 2, never 0.")
    p.add_argument("--halide-sha256", default=None, metavar="HEX",
                   help="Verify the downloaded Halide distribution against this sha256, "
                        "overriding the built-in table. Use this if you have an INDEPENDENTLY "
                        "corroborated hash: the built-in values are trust-on-first-use (read "
                        "once from the same server that serves the asset), so they catch a "
                        "future substitution but not one that predates 2026-08-22.")
    p.add_argument("--clean", action="store_true",
                   help="Delete this target's build output before building (needed after a CMake "
                        "target rename - a cached target name cannot be updated in place).")
    p.add_argument("--strict", action="store_true",
                   help="Exit 2 if any warning was raised.")
    p.add_argument("--macos-arch", choices=["arm64", "x86_64", "universal"],
                   default=MACOS_DEFAULT_ARCH,
                   help=f"macOS architecture (default: {MACOS_DEFAULT_ARCH}). Intel/universal is "
                        "parked: the prebuilt decoder dylib is arm64-only, so a universal app's "
                        "x86_64 slice links without native RAW decode.")
    p.add_argument("--print-halide-pins", action="store_true",
                   help="Print the pinned Halide sha256 table and exit.")
    p.add_argument("--ios-codesign", action="store_true",
                   help="Let `flutter build ios` codesign (default: --no-codesign).")
    p.add_argument("--root", default=None,
                   help="Folder holding Halcyon/ and ceyx/ (default: auto-detect).")
    p.add_argument("--decoder", default=None,
                   help="Path to the ceyx checkout (same flag name as "
                        "package_windows.sh). Default: a sibling of the Halcyon checkout.")
    return p


def print_halide_pins():
    print(f"Halide v{HALIDE_VERSION} @ {HALIDE_COMMIT}")
    for (os_name, arch), (plat, ext) in sorted(HALIDE_PLATFORMS.items()):
        pin = HALIDE_SHA256.get(plat)
        print(f"  {os_name:<8} {arch:<8} Halide-{HALIDE_VERSION}-{plat}-{HALIDE_COMMIT}.{ext}")
        print(f"           sha256 {pin if pin else 'MISSING - integrity unverified on this host'}")
    print()
    print("STATUS: trust-on-first-use, NOT an independently verified pin.")
    print("  Read from the GitHub release API on 2026-08-22 - the same authority that serves")
    print("  the bytes. Catches a future asset substitution; cannot catch one that predates")
    print("  that date. Upstream publishes no .sha256/.asc/.sig asset to cross-check.")
    print("  To turn these into a real pin: have someone else, on a different machine and")
    print("  network, run `shasum -a 256 <asset>` and confirm the value, then record who")
    print("  verified it and when beside the constant in this script.")
    print("Re-read the server's view with:")
    print("  curl -s https://api.github.com/repos/halide/Halide/releases/tags/v21.0.0")


def main():
    args = make_parser().parse_args()

    # Absolutize the S4 sample now: build_apps.py runs from the Halcyon repo, so
    # a relative --cfa-sample-dng passes the Phase-0 existence check here, but
    # test_cfa_color is invoked by run_checked with cwd=native/build, where the
    # same relative path resolves to nothing and LibRaw returns DATA_ERROR
    # (100008) on an empty read. Pinning it to an absolute path once removes the
    # cwd dependency for every downstream consumer.
    if args.cfa_sample_dng:
        args.cfa_sample_dng = os.path.abspath(args.cfa_sample_dng)

    if args.print_halide_pins:
        print_halide_pins()
        return

    print("=" * 62)
    print(" Halcyon build_apps.py - native + Flutter, one entry point")
    print("=" * 62)

    refresh_env_from_registry()
    layout = resolve_layout(args.root)
    if args.decoder:
        layout.decoder = Path(args.decoder).resolve()
    mode = resolve_mode(args)

    step(f"halcyon: {layout.halcyon}")
    step(f"decoder: {layout.decoder}")
    step(f"host:    {host_os()}/{host_arch()}  mode: {mode}")

    aborted = False
    try:
        if args.target == "all":
            if args.check:
                for t in ALL_TARGETS:
                    if supports_target(t):
                        build_target(t, layout, mode, args)
            else:
                build_all(layout, mode, args)
        else:
            build_target(args.target, layout, mode, args)
    except SystemExit:
        aborted = True  # fail() on its way out - do not label that run "DONE"
        raise
    finally:
        # The summary must print on every exit path, including the
        # --native-target early return, so warnings can never vanish.
        print()
        print("=" * 62)
        if aborted:
            print(f" ABORTED with {WARNING_COUNT} warning(s) - see the ERROR above."
                  if WARNING_COUNT else " ABORTED - see the ERROR above.")
        elif WARNING_COUNT:
            print(f" DONE with {WARNING_COUNT} warning(s) - review the [warn] lines above.")
        else:
            print(" DONE - no warnings.")
        print("=" * 62)

    if COLOUR_GATE_SKIPPED:
        print(" EXIT 2: a native library was placed WITHOUT the runbook S4 colour gate.")
        sys.exit(2)
    if args.strict and WARNING_COUNT:
        print(f" EXIT 2: --strict and {WARNING_COUNT} warning(s).")
        sys.exit(2)


if __name__ == "__main__":
    main()
