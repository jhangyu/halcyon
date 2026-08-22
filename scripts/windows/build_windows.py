#!/usr/bin/env python3
"""One-click Windows build for the Halcyon RAW decode stack (W12 + W14).

Python port of build_windows.ps1. Faithful transcription of
docs/logs/2026-08-21/windows-ffi-build-runbook.md - every check and command
maps to a numbered section of that runbook (noted inline as "runbook Sx").
This script does not invent alternative build routes: if something the
runbook prescribes is missing, it stops and says so instead of routing
around it.

Layout expected (produced by scripts/package_windows.sh):

    <this folder>\
      build_windows.py     <- you are here
      README_WINDOWS.md
      Halcyon\
      flutter_dng_decoder\

Phases:
  Phase 0  prerequisite checks            (runbook S1, S3 preamble)
  Phase 0b Halide v21 distribution        (runbook S1 last row / W1)
  Phase 1  W12 - build dng_decoder_native (runbook S3, S4)
  Phase 2  W14 - flutter build windows    (runbook S5)
  Phase 3  print manual verification protocol (runbook S5, S6)

Unlike the PowerShell version, this script does not require being launched
from an "x64 Native Tools Command Prompt": if INCLUDE/LIB are not already
set, it locates the Visual Studio installation via vswhere and injects the
vcvars64.bat environment itself.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import urllib.request
import winreg
import zipfile
from pathlib import Path

HALIDE_COMMIT = "b629c80de18f1534ec71fddd8b567aa7027a0876"
HALIDE_ASSET = f"Halide-21.0.0-x86-64-windows-{HALIDE_COMMIT}.zip"
HALIDE_URL = f"https://github.com/halide/Halide/releases/download/v21.0.0/{HALIDE_ASSET}"

WARNING_COUNT = 0
CURRENT_PHASE = "startup"


def phase(name):
    global CURRENT_PHASE
    CURRENT_PHASE = name
    print()
    print(f"==> {name}")


def step(msg):
    print(f"    {msg}")


def ok(msg):
    print(f"    [ok]   {msg}")


def warn(msg):
    global WARNING_COUNT
    WARNING_COUNT += 1
    print(f"    [warn] {msg}")


def fail(msg, hints=None):
    print()
    print(f"ERROR in {CURRENT_PHASE}: {msg}")
    for h in hints or []:
        print(f"       -> {h}")
    print()
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


# ---------------------------------------------------------------------------
# Environment bootstrap: refresh PATH/env from the registry (this process's
# inherited env can be stale relative to tools installed after the parent
# shell started), then inject the MSVC dev environment if not already present.
# ---------------------------------------------------------------------------
def _read_registry_env(root, subkey):
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
    machine = _read_registry_env(
        winreg.HKEY_LOCAL_MACHINE,
        r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment",
    )
    user = _read_registry_env(winreg.HKEY_CURRENT_USER, "Environment")

    path_parts = [os.environ.get("Path", "")]
    if machine.get("Path"):
        path_parts.insert(0, machine["Path"])
    if user.get("Path"):
        path_parts.insert(1, user["Path"])
    os.environ["Path"] = ";".join(p for p in path_parts if p)

    for src in (machine, user):
        for k, v in src.items():
            if k.lower() == "path":
                continue
            os.environ.setdefault(k, v)


def locate_vs_install():
    vswhere = (
        Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"))
        / "Microsoft Visual Studio"
        / "Installer"
        / "vswhere.exe"
    )
    if not vswhere.exists():
        return None
    try:
        proc = subprocess.run(
            [str(vswhere), "-latest", "-products", "*", "-property", "installationPath"],
            capture_output=True,
            timeout=30,
        )
    except OSError:
        return None
    text = decode_bytes(proc.stdout).strip()
    return Path(text) if text else None


def ensure_msvc_env():
    """Ensure INCLUDE/LIB/PATH have the MSVC + clang-cl toolchain (runbook S3)."""
    if os.environ.get("INCLUDE") and os.environ.get("LIB"):
        return True

    vs_install = locate_vs_install()
    if vs_install is None:
        return False
    vcvars = vs_install / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
    if not vcvars.exists():
        return False

    try:
        # shell=True is required here: cmd.exe's own /c argument parsing does
        # not compose with Python's argv-list quoting when the batch path
        # contains spaces (e.g. "Program Files (x86)"), so build the whole
        # "call vcvars && set" line as a single string for the shell instead.
        proc = subprocess.run(
            f'"{vcvars}" && set',
            shell=True,
            capture_output=True,
            timeout=120,
        )
    except OSError:
        return False
    if proc.returncode != 0:
        return False

    text = decode_bytes(proc.stdout)
    env = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        if k and not k.startswith("*"):
            env[k] = v
    if "INCLUDE" not in env or "LIB" not in env:
        return False
    os.environ.update(env)
    return True


# ---------------------------------------------------------------------------
# Subprocess helpers
# ---------------------------------------------------------------------------
def run_checked(exe, args, cwd, what):
    step(f"{exe} {' '.join(args)}")
    # Windows CreateProcess() cannot exec a .BAT/.CMD directly (flutter is
    # shipped as flutter.bat); it needs a command interpreter. Resolve the
    # exe's real path so this decision is based on what's actually on disk,
    # not just the bare name, then route batch files through shell=True.
    # With shell=True on Windows, Popen still accepts an argv list and
    # quotes it itself (subprocess.list2cmdline) before handing it to
    # cmd.exe /c - this avoids hand-building a quoted command string, which
    # has its own escaping pitfalls (see build_windows.py's ensure_msvc_env
    # for a case where that was unavoidable).
    resolved = shutil.which(exe) or exe
    use_shell = resolved.lower().endswith((".bat", ".cmd"))
    proc = subprocess.Popen(
        [resolved, *args],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=1,
        universal_newlines=False,
        shell=use_shell,
    )
    for line in proc.stdout:
        sys.stdout.write(decode_bytes(line))
    proc.wait()
    if proc.returncode != 0:
        fail(
            f"{what} failed (exit code {proc.returncode}).",
            hints=[
                "Fix the reported compiler/linker error before re-running.",
                "The runbook S3 lists the four most likely first-contact configure failures.",
                "Re-running this script after a fix is safe: every phase is idempotent.",
            ],
        )
    ok(what)


def which(name):
    return shutil.which(name)


# ---------------------------------------------------------------------------
# Phase 0b: Halide v21 distribution
# ---------------------------------------------------------------------------
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

    try:
        urllib.request.urlretrieve(url, dest, reporthook=_report)
    except Exception as e:  # noqa: BLE001 - surfaced via fail()
        fail(
            f"download of {os.path.basename(dest)} failed: {e}",
            hints=[
                f"Download it manually from {url}",
                "Extract it so that <native>/third_party/halide/lib/Halide.lib exists, then re-run.",
                "Runbook S1 documents this manual path as the supported workaround.",
            ],
        )


def extract_halide(zip_path, stage_dir):
    """Extract the Halide zip, skipping share/doc/* (Doxygen HTML with
    Windows-MAX_PATH-busting filenames that are not needed for the build)."""
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
        skipped = 0
        for name in names:
            normalized = name.replace("\\", "/").lower()
            if "/share/doc/" in normalized:
                skipped += 1
                continue
            zf.extract(name, stage_dir)
        if skipped:
            step(f"skipped {skipped} doc entries under share/doc/ (not needed for the build)")


def ensure_halide(native_dir):
    halide_dir = native_dir / "third_party" / "halide"
    halide_lib = halide_dir / "lib" / "Halide.lib"
    if halide_lib.exists():
        ok(f"already present: {halide_dir}")
        return

    import tempfile

    with tempfile.TemporaryDirectory(prefix="halide21_") as tmp:
        tmp = Path(tmp)
        zip_path = tmp / HALIDE_ASSET
        download_with_progress(HALIDE_URL, str(zip_path))

        stage_dir = tmp / "x"
        stage_dir.mkdir(parents=True, exist_ok=True)
        extract_halide(zip_path, stage_dir)

        tops = [p for p in stage_dir.iterdir() if p.is_dir()]
        if not tops:
            fail(f"unexpected archive layout in {HALIDE_ASSET} (no top-level folder).")
        top = tops[0]

        halide_dir.mkdir(parents=True, exist_ok=True)
        for item in top.iterdir():
            dest = halide_dir / item.name
            if item.is_dir():
                shutil.copytree(item, dest, dirs_exist_ok=True)
            else:
                shutil.copy2(item, dest)

        # The v21.0.0 Windows asset nests the actual .lib under lib\Release\
        # (multi-config layout) rather than lib\Halide.lib directly. Mirror it
        # up one level to match what CMakeLists' find_package(Halide) and this
        # script's own sanity check expect.
        nested_lib = halide_dir / "lib" / "Release" / "Halide.lib"
        if nested_lib.exists() and not halide_lib.exists():
            step(f"mirroring {nested_lib} -> {halide_lib}")
            shutil.copy2(nested_lib, halide_lib)

        if not halide_lib.exists():
            fail(f"Halide extraction finished but {halide_lib} is still missing.")

        version_text = (
            "halide/Halide@v21.0.0\r\n"
            "binary_provenance: vendored from https://github.com/halide/Halide/releases/tag/v21.0.0\r\n"
            f"asset: {HALIDE_ASSET}\r\n"
            "abi_notes: schedule changes break AOT artifacts; bump requires full regen.\r\n"
        )
        (halide_dir / "VERSION").write_text(version_text, encoding="ascii")

    ok(f"installed: {halide_dir}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="One-click Windows build for the Halcyon RAW decode stack.")
    parser.add_argument("--root", default=None, help="Folder holding Halcyon/ and flutter_dng_decoder/ (default: this script's folder)")
    parser.add_argument("--cfa-sample-dng", default="", help="Optional path to a blue-sky DNG sample for the colour gate (runbook S4)")
    parser.add_argument("--skip-flutter-build", action="store_true", help="Run Phase 0/1 only (native DLL), skip Phase 2 (flutter build)")
    parser.add_argument("--native-target", default=None, nargs="+", metavar="TARGET", help="Configure, then build only these native targets and stop (iteration aid; skips DLL placement and Phase 2)")
    args = parser.parse_args()

    print("=" * 60)
    print(" Halcyon Windows RAW decode build (W12 + W14)")
    print(" Runbook: Halcyon/docs/logs/2026-08-21/windows-ffi-build-runbook.md")
    print("=" * 60)

    refresh_env_from_registry()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parent

    # -------------------------------------------------------------------
    # Phase 0 - prerequisites (runbook S1 table, S2 layout, S3 preamble)
    # -------------------------------------------------------------------
    phase("Phase 0: prerequisite checks")

    halcyon_dir = root / "Halcyon"
    decoder_dir = root / "flutter_dng_decoder"
    native_dir = decoder_dir / "dng_processor" / "native"
    ffi_lib_dir = decoder_dir / "dng_processor_ffi" / "windows" / "Libraries"

    for needed in (halcyon_dir, decoder_dir, native_dir):
        if not needed.exists():
            fail(
                f"Expected folder not found: {needed}",
                hints=[
                    "Extract the whole zip and run this script from the extracted root.",
                    "Layout must be <root>\\Halcyon and <root>\\flutter_dng_decoder as siblings (runbook S2).",
                ],
            )
    ok(f"layout: {halcyon_dir} + {decoder_dir}")

    presets_file = native_dir / "CMakePresets.json"
    if not presets_file.exists():
        fail(f"CMakePresets.json not found at {presets_file}")
    presets_text = presets_file.read_text(encoding="utf-8", errors="replace")
    if '"windows-vulkan"' not in presets_text:
        fail(
            "The windows-vulkan CMake preset (W9) is missing from CMakePresets.json.",
            hints=["Runbook S3: do not hand-invent a preset - report back that W9 has not landed."],
        )
    ok("CMake preset windows-vulkan present (W9)")

    if not ensure_msvc_env():
        fail(
            "Could not establish an MSVC environment (INCLUDE/LIB).",
            hints=[
                "Start an \"x64 Native Tools Command Prompt for VS 2022\", or run vcvars64.bat first, then re-run.",
                "Or ensure Visual Studio Build Tools with the C++ workload is installed so vswhere/vcvars64.bat can be found.",
            ],
        )

    clang_cl = which("clang-cl")
    if not clang_cl:
        fail(
            "clang-cl was not found on PATH.",
            hints=[
                'Install the "C++ Clang tools for Windows" component in the Visual Studio Installer, or standalone LLVM.',
                "Runbook S1: cl.exe is NOT sufficient - the byte-exact colour contract needs -ffp-contract=off.",
            ],
        )
    ok(f"clang-cl: {clang_cl}")

    cmake_exe = which("cmake")
    if not cmake_exe:
        fail("cmake was not found on PATH.", hints=["Install CMake 3.14 or newer."])
    ver_out = decode_bytes(subprocess.run([cmake_exe, "--version"], capture_output=True).stdout)
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", ver_out) or re.search(r"(\d+)\.(\d+)", ver_out)
    if not m:
        warn(f"could not parse CMake version from: {ver_out.splitlines()[0] if ver_out else ''}")
    else:
        version_tuple = tuple(int(g) for g in m.groups() if g is not None)
        if version_tuple < (3, 14):
            fail(f"CMake {'.'.join(map(str, version_tuple))} is older than the required 3.14 (runbook S1).")
        ok(f"cmake: {'.'.join(map(str, version_tuple))} ({cmake_exe})")

    ninja_exe = which("ninja")
    if not ninja_exe:
        fail(
            "ninja was not found on PATH.",
            hints=["The windows-vulkan preset uses the Ninja generator; it ships with the VS C++ workload or install separately."],
        )
    ok(f"ninja: {ninja_exe}")

    ok("MSVC environment (INCLUDE/LIB) present")

    if not os.environ.get("VULKAN_SDK"):
        fail(
            "VULKAN_SDK is not set.",
            hints=["Install the LunarG Vulkan SDK - its installer sets VULKAN_SDK automatically."],
        )
    vulkan_lib = Path(os.environ["VULKAN_SDK"]) / "Lib" / "vulkan-1.lib"
    if not vulkan_lib.exists():
        fail(f"vulkan-1.lib not found at {vulkan_lib}", hints=["VULKAN_SDK points at a folder without Lib\\vulkan-1.lib."])
    ok(f"Vulkan SDK: {os.environ['VULKAN_SDK']}")

    vulkaninfo = which("vulkaninfo")
    if not vulkaninfo:
        warn("vulkaninfo not on PATH - cannot pre-check GPU/driver Vulkan 1.1+ support.")
    else:
        ok(f"vulkaninfo: {vulkaninfo} (run it manually to confirm apiVersion >= 1.1 before trusting decode results)")

    nasm_exe = which("nasm")
    if not nasm_exe:
        warn("nasm not found - libjpeg-turbo will build with WITH_SIMD=OFF (optional, safe to defer).")
    else:
        ok(f"nasm: {nasm_exe}")

    flutter_exe = which("flutter") or which("flutter.bat")
    if not flutter_exe:
        if args.skip_flutter_build:
            warn("flutter not on PATH - fine, --skip-flutter-build was requested.")
        else:
            fail(
                "flutter was not found on PATH.",
                hints=["Install Flutter and add its bin folder to PATH, then re-run.", "Or run with --skip-flutter-build."],
            )
    else:
        ok(f"flutter: {flutter_exe}")

    if args.cfa_sample_dng and not Path(args.cfa_sample_dng).exists():
        fail(f"--cfa-sample-dng file not found: {args.cfa_sample_dng}")

    # -------------------------------------------------------------------
    # Phase 0b - Halide v21 distribution (runbook S1 last row / W1)
    # -------------------------------------------------------------------
    phase("Phase 0b: Halide v21 distribution")
    ensure_halide(native_dir)

    # -------------------------------------------------------------------
    # Phase 1 - W12: configure, build, place the DLL (runbook S3 + S4)
    # -------------------------------------------------------------------
    phase("Phase 1: W12 - build dng_decoder_native")

    run_checked("cmake", ["--preset", "windows-vulkan"], str(native_dir), "cmake configure (windows-vulkan)")

    if args.native_target:
        targets = " ".join(args.native_target)
        run_checked(
            "cmake",
            ["--build", "--preset", "windows-vulkan", "--target", *args.native_target],
            str(native_dir),
            f"cmake build ({targets})",
        )
        ok(f"--native-target {targets} built; stopping before DLL placement.")
        return

    run_checked(
        "cmake",
        ["--build", "--preset", "windows-vulkan", "--target", "dng_decoder_native"],
        str(native_dir),
        "cmake build (dng_decoder_native)",
    )

    build_dir = native_dir / "build-windows"
    built_dll = build_dir / "dng_decoder_native.dll"
    if not built_dll.exists():
        fail(
            f"build succeeded but {built_dll} does not exist.",
            hints=[
                "Runbook S3 expects exactly this filename (add_library(dng_decoder_native SHARED) on Windows).",
                "Check the Ninja output above for where the shared library was actually written.",
            ],
        )
    ok(f"built: {built_dll}")

    if args.cfa_sample_dng:
        run_checked(
            "cmake",
            ["--build", "--preset", "windows-vulkan", "--target", "test_cfa_color"],
            str(native_dir),
            "cmake build (test_cfa_color)",
        )
        cfa_exe = build_dir / "test_cfa_color.exe"
        if not cfa_exe.exists():
            fail(f"test_cfa_color.exe not found at {cfa_exe}")
        run_checked(str(cfa_exe), [args.cfa_sample_dng, "--expect-blue-sky"], str(build_dir), "test_cfa_color colour gate")
    else:
        warn("colour gate skipped: no --cfa-sample-dng given.")
        step("Runbook S4 requires test_cfa_color (blue-sky B >> R) to pass before the DLL is trusted.")
        step("To run it later:")
        step(f"  cmake --build --preset windows-vulkan --target test_cfa_color   (from {native_dir})")
        step(f"  {build_dir}\\test_cfa_color.exe <blue-sky.dng> --expect-blue-sky")

    ffi_lib_dir.mkdir(parents=True, exist_ok=True)
    placed_dll = ffi_lib_dir / "dng_decoder_native.dll"
    shutil.copy2(built_dll, placed_dll)
    if not placed_dll.exists():
        fail(f"copy to {ffi_lib_dir} did not produce dng_decoder_native.dll")
    ok(f"placed: {placed_dll}")
    step("This extracted tree is not a git checkout (the zip carries source only),")
    step("so the runbook S4 \"git add / git rm .gitkeep / git commit\" step cannot run here.")
    step("Copy this DLL back to the flutter_dng_decoder repo and commit it there per runbook S4.")

    # -------------------------------------------------------------------
    # Phase 2 - W14: end-to-end Halcyon build (runbook S5)
    # -------------------------------------------------------------------
    if args.skip_flutter_build:
        phase("Phase 2: W14 - skipped (--skip-flutter-build)")
    else:
        phase("Phase 2: W14 - flutter build windows")

        run_checked("flutter", ["pub", "get"], str(halcyon_dir), "flutter pub get")
        run_checked("flutter", ["build", "windows", "--release"], str(halcyon_dir), "flutter build windows --release")

        release_dir = halcyon_dir / "build" / "windows" / "x64" / "runner" / "Release"
        bundled_dll = release_dir / "dng_decoder_native.dll"
        if not bundled_dll.exists():
            print()
            print("    Packaging check FAILED - running the runbook S5 diagnostics:")
            gen_plugins = halcyon_dir / "windows" / "flutter" / "generated_plugins.cmake"
            if gen_plugins.exists():
                gen_text = gen_plugins.read_text(encoding="utf-8", errors="replace")
                if "dng_processor_ffi" in gen_text:
                    print("    1. generated_plugins.cmake DOES list dng_processor_ffi (plugin was discovered).")
                else:
                    print("    1. generated_plugins.cmake does NOT list dng_processor_ffi.")
                    print("       -> flutter pub get did not pick up the plugin declaration (W10).")
                    print("       -> try: flutter clean, then re-run this script (stale generated files).")
            else:
                print(f"    1. {gen_plugins} is missing entirely.")
            print(f"    2. Check that {placed_dll} existed at configure time (a stale CMake cache from")
            print("       before Phase 1 can still hold the empty value). Try: flutter clean, then re-run.")
            print("       Then grep the CMake log for dng_processor_ffi_bundled_libraries; if it")
            print("       resolves to empty, that is the silent-failure mode documented in")
            print("       dng_processor_ffi/windows/CMakeLists.txt.")
            fail(
                f"dng_decoder_native.dll is not in {release_dir}",
                hints=["Runbook S5: do not manually copy the DLL as a workaround - it would hide a real packaging bug."],
            )
        ok(f"bundled: {bundled_dll}")

        exe_files = list(release_dir.glob("*.exe"))
        if not exe_files:
            warn(f"no .exe found in {release_dir} - the DLL is there but the runner is not.")
        else:
            for exe in exe_files:
                ok(f"runner exe alongside it: {exe.name}")

        # -----------------------------------------------------------------
        # Phase 3 - manual verification protocol (runbook S5 + S6)
        # -----------------------------------------------------------------
        phase("Phase 3: manual verification (this script does not automate it)")
        print()
        print("    Runbook S5 - correctness:")
        print(f"      1. Launch {release_dir}\\<runner>.exe")
        print("      2. Open DNG files from local_data\\photo_samples\\DNG\\ ONLY.")
        print("         NOTE: photo samples are not shipped in this zip - copy them over yourself.")
        print("      3. Confirm DngResult.errorCode == 0 for each sample.")
        print("      4. Confirm there is no RAW_UNSUPPORTED / MISSING_PLUGIN fallback to the Dart")
        print("         preview path - a silent fallback would look like success while native decode failed.")
        print()
        print("    Runbook S6 - timing (the 1-second gate):")
        print("      1. Pick 3-5 representative DNG samples.")
        print("      2. COLD-LAUNCH the exe for every \"first decode\" measurement (fresh process each time).")
        print("      3. Record wall-clock \"decode requested\" -> \"decode complete\" (decodeMs + processMs).")
        print("      4. HARD GATE: if any first decode exceeds 1000 ms, STOP. Do not average it away,")
        print("         do not retry until fast, do not report a warm number. Record: exact ms, which")
        print("         sample, GPU model + driver version (vulkaninfo), and whether a second cold")
        print("         launch shows the same first-decode latency.")
        print("      5. Then, in the SAME warm process, decode 5-10 more samples and record")
        print("         min/median/max separately (these should be fast, ~110 ms macOS Metal baseline).")
        print("      6. If the gate is breached: write a handover document first. Do NOT start the")
        print("         VkPipelineCache persistence work directly (runbook S6).")
        print("      7. If the gate passes: record the numbers in runbook section 7 \"Results\".")

    print()
    print("=" * 60)
    if WARNING_COUNT > 0:
        print(f" DONE with {WARNING_COUNT} warning(s) - review the [warn] lines above.")
    else:
        print(" DONE - no warnings.")
    print("=" * 60)


if __name__ == "__main__":
    main()
