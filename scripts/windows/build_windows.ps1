<#
.SYNOPSIS
    One-click Windows build for the Halcyon RAW decode stack (W12 + W14).

.DESCRIPTION
    Faithful transcription of docs/logs/2026-08-21/windows-ffi-build-runbook.md.
    Every check and command below maps to a numbered section of that runbook;
    the mapping is noted inline as "runbook Sx" comments. This script does not
    invent alternative build routes: if something the runbook prescribes is
    missing, it stops and says so instead of routing around it.

    Layout expected (produced by scripts/package_windows.sh):

        <this folder>\
          build_windows.ps1        <- you are here
          README_WINDOWS.md
          Halcyon\
          flutter_dng_decoder\

    Phases:
      Phase 0  prerequisite checks            (runbook S1, S3 preamble)
      Phase 0b Halide v21 distribution        (runbook S1 last row / W1)
      Phase 1  W12 - build dng_decoder_native (runbook S3, S4)
      Phase 2  W14 - flutter build windows    (runbook S5)
      Phase 3  print manual verification protocol (runbook S5, S6)

    Run from an "x64 Native Tools Command Prompt for VS 2022" (or after
    vcvars64.bat) so clang-cl and the Windows SDK are on PATH - runbook S3.

.PARAMETER Root
    Folder holding the Halcyon\ and flutter_dng_decoder\ siblings.
    Defaults to the folder containing this script.

.PARAMETER CfaSampleDng
    Optional path to a blue-sky DNG sample. When supplied, Phase 1 also builds
    and runs test_cfa_color against it, which is the colour gate the runbook
    requires before the DLL is considered good (runbook S4). Photo samples are
    deliberately NOT shipped in the zip, so this is opt-in.

.PARAMETER SkipFlutterBuild
    Run Phase 0/1 only (produce and place the DLL), skip Phase 2.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build_windows.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build_windows.ps1 -CfaSampleDng D:\samples\sky.dng
#>
[CmdletBinding()]
param(
    [string] $Root = $PSScriptRoot,
    [string] $CfaSampleDng = '',
    [switch] $SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'

# Halide v21.0.0 Windows x64 asset. Same release/build-commit as the macOS and
# Android hosts use, so the AOT ABI matches third_party/halide/VERSION.
# Source: runbook S1 "Halide v21 Windows distribution" row, and
# flutter_dng_decoder/dng_processor/native/scripts/fetch_halide_v21_dist.sh.
$script:HalideCommit = 'b629c80de18f1534ec71fddd8b567aa7027a0876'
$script:HalideAsset  = "Halide-21.0.0-x86-64-windows-$($script:HalideCommit).zip"
$script:HalideUrl    = "https://github.com/halide/Halide/releases/download/v21.0.0/$($script:HalideAsset)"

$script:CurrentPhase = 'startup'
$script:WarningCount = 0

function Write-Phase {
    param([string] $Name)
    $script:CurrentPhase = $Name
    Write-Host ''
    Write-Host "==> $Name"
}

function Write-Step {
    param([string] $Message)
    Write-Host "    $Message"
}

function Write-Ok {
    param([string] $Message)
    Write-Host "    [ok]   $Message"
}

function Write-Warn {
    param([string] $Message)
    $script:WarningCount = $script:WarningCount + 1
    Write-Host "    [warn] $Message"
}

function Stop-WithError {
    param([string] $Message, [string[]] $Hints = @())
    Write-Host ''
    Write-Host "ERROR in $($script:CurrentPhase): $Message"
    foreach ($hint in $Hints) {
        Write-Host "       -> $hint"
    }
    Write-Host ''
    exit 1
}

function Get-ToolPath {
    param([string] $Name)
    $found = @(Get-Command -Name $Name -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { return '' }
    $first = $found[0]
    $pathProperty = $first.PSObject.Properties['Path']
    if ($null -ne $pathProperty -and $pathProperty.Value) {
        return [string] $pathProperty.Value
    }
    return [string] $first.Name
}

function Invoke-Checked {
    param(
        [string]   $Exe,
        [string[]] $ExeArgs,
        [string]   $WorkingDirectory,
        [string]   $What
    )
    Write-Step "$Exe $($ExeArgs -join ' ')"
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $Exe @ExeArgs
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -ne 0) {
        Stop-WithError -Message "$What failed (exit code $code)." -Hints @(
            'Fix the reported compiler/linker error before re-running.',
            'The runbook S3 lists the four most likely first-contact configure failures.',
            'Re-running this script after a fix is safe: every phase is idempotent.'
        )
    }
    Write-Ok "$What"
}

Write-Host '============================================================'
Write-Host ' Halcyon Windows RAW decode build (W12 + W14)'
Write-Host ' Runbook: Halcyon/docs/logs/2026-08-21/windows-ffi-build-runbook.md'
Write-Host '============================================================'

# ---------------------------------------------------------------------------
# Phase 0 - prerequisites (runbook S1 table, S2 layout, S3 preamble)
# ---------------------------------------------------------------------------
Write-Phase 'Phase 0: prerequisite checks'

if ([string]::IsNullOrEmpty($Root)) {
    Stop-WithError -Message 'Could not determine the pack root.' -Hints @(
        'Pass it explicitly: -Root C:\path\to\extracted\zip'
    )
}
$Root = (Resolve-Path -LiteralPath $Root).Path

# runbook S2 - repo layout: the two checkouts must be siblings, because
# Halcyon/pubspec.yaml depends on ../flutter_dng_decoder/dng_processor_ffi.
$HalcyonDir = Join-Path $Root 'Halcyon'
$DecoderDir = Join-Path $Root 'flutter_dng_decoder'
$NativeDir  = Join-Path $DecoderDir 'dng_processor\native'
$FfiLibDir  = Join-Path $DecoderDir 'dng_processor_ffi\windows\Libraries'

foreach ($needed in @($HalcyonDir, $DecoderDir, $NativeDir)) {
    if (-not (Test-Path -LiteralPath $needed)) {
        Stop-WithError -Message "Expected folder not found: $needed" -Hints @(
            'Extract the whole zip and run this script from the extracted root.',
            'Layout must be <root>\Halcyon and <root>\flutter_dng_decoder as siblings (runbook S2).'
        )
    }
}
Write-Ok "layout: $HalcyonDir + $DecoderDir"

# runbook S3 - "check native/CMakePresets.json for a windows-vulkan entry
# before proceeding. If it is missing, do not hand-invent a preset."
$PresetsFile = Join-Path $NativeDir 'CMakePresets.json'
if (-not (Test-Path -LiteralPath $PresetsFile)) {
    Stop-WithError -Message "CMakePresets.json not found at $PresetsFile"
}
$presetsText = Get-Content -LiteralPath $PresetsFile -Raw
if ($presetsText -notmatch '"windows-vulkan"') {
    Stop-WithError -Message 'The windows-vulkan CMake preset (W9) is missing from CMakePresets.json.' -Hints @(
        'Runbook S3: do not hand-invent a preset - report back that W9 has not landed.'
    )
}
Write-Ok 'CMake preset windows-vulkan present (W9)'

# runbook S1 - clang-cl is mandatory (-ffp-contract=off has no cl.exe equivalent).
$clangCl = Get-ToolPath 'clang-cl'
if ($clangCl -eq '') {
    Stop-WithError -Message 'clang-cl was not found on PATH.' -Hints @(
        'Install the "C++ Clang tools for Windows" component in the Visual Studio Installer, or standalone LLVM.',
        'Open an "x64 Native Tools Command Prompt for VS 2022" so clang-cl is on PATH.',
        'Runbook S1: cl.exe is NOT sufficient - the byte-exact colour contract needs -ffp-contract=off.'
    )
}
Write-Ok "clang-cl: $clangCl"

# runbook S1 - CMake 3.14+.
$cmakeExe = Get-ToolPath 'cmake'
if ($cmakeExe -eq '') {
    Stop-WithError -Message 'cmake was not found on PATH.' -Hints @(
        'Install CMake 3.14 or newer (it ships with the Visual Studio C++ workload).'
    )
}
$cmakeVersionLine = (& cmake --version | Select-Object -First 1)
$cmakeVersion = $null
if ($cmakeVersionLine -match '(\d+)\.(\d+)\.(\d+)') {
    $cmakeVersion = [version] "$($matches[1]).$($matches[2]).$($matches[3])"
} elseif ($cmakeVersionLine -match '(\d+)\.(\d+)') {
    $cmakeVersion = [version] "$($matches[1]).$($matches[2])"
}
if ($null -eq $cmakeVersion) {
    Write-Warn "could not parse CMake version from: $cmakeVersionLine"
} elseif ($cmakeVersion -lt [version] '3.14') {
    Stop-WithError -Message "CMake $cmakeVersion is older than the required 3.14 (runbook S1)."
} else {
    Write-Ok "cmake: $cmakeVersion ($cmakeExe)"
}

# The windows-vulkan preset uses the Ninja generator (CMakePresets.json), which
# the runbook drives through "cmake --preset windows-vulkan" in S3.
$ninjaExe = Get-ToolPath 'ninja'
if ($ninjaExe -eq '') {
    Stop-WithError -Message 'ninja was not found on PATH.' -Hints @(
        'The windows-vulkan preset uses the Ninja generator.',
        'Ninja ships with the Visual Studio C++ workload - use the x64 Native Tools Command Prompt, or install Ninja separately.'
    )
}
Write-Ok "ninja: $ninjaExe"

# runbook S3 - must run from a Developer Command Prompt so Ninja/clang-cl can
# find the MSVC headers and libs (the preset description says the same).
$hasMsvcEnv = $false
if ((Test-Path Env:INCLUDE) -and (Test-Path Env:LIB)) { $hasMsvcEnv = $true }
if (-not $hasMsvcEnv) {
    Stop-WithError -Message 'MSVC environment not detected (INCLUDE / LIB are not set).' -Hints @(
        'Start an "x64 Native Tools Command Prompt for VS 2022", or run vcvars64.bat first, then re-run this script.',
        'Runbook S3: the build must run from a Developer Command Prompt for VS 2022.'
    )
}
Write-Ok 'MSVC environment (INCLUDE/LIB) present'

# runbook S1 - Vulkan SDK; build needs $VULKAN_SDK/Lib/vulkan-1.lib and headers.
if (-not (Test-Path Env:VULKAN_SDK)) {
    Stop-WithError -Message 'VULKAN_SDK is not set.' -Hints @(
        'Install the LunarG Vulkan SDK - its installer sets VULKAN_SDK automatically.',
        'Open a new shell after installing so the variable is visible.'
    )
}
$vulkanLib = Join-Path $env:VULKAN_SDK 'Lib\vulkan-1.lib'
if (-not (Test-Path -LiteralPath $vulkanLib)) {
    Stop-WithError -Message "vulkan-1.lib not found at $vulkanLib" -Hints @(
        'VULKAN_SDK points at a folder without Lib\vulkan-1.lib - check the SDK installation (runbook S1).'
    )
}
Write-Ok "Vulkan SDK: $env:VULKAN_SDK"

# runbook S1 - a Vulkan 1.1+ GPU/driver is a RUNTIME requirement; vulkaninfo is
# the recommended way to check it. Informational only: absence does not block
# the build, it blocks decoding later.
$vulkanInfo = Get-ToolPath 'vulkaninfo'
if ($vulkanInfo -eq '') {
    Write-Warn 'vulkaninfo not on PATH - cannot pre-check GPU/driver Vulkan 1.1+ support (runbook S1 runtime requirement).'
} else {
    Write-Ok "vulkaninfo: $vulkanInfo (run it manually to confirm apiVersion >= 1.1 before trusting decode results)"
}

# runbook S1 - NASM is optional: without it the vendored libjpeg-turbo builds
# with WITH_SIMD=OFF, which CMakeLists already falls back to automatically.
$nasmExe = Get-ToolPath 'nasm'
if ($nasmExe -eq '') {
    Write-Warn 'nasm not found - libjpeg-turbo will build with WITH_SIMD=OFF (runbook S1: optional, safe to defer).'
} else {
    Write-Ok "nasm: $nasmExe"
}

# runbook S5 - flutter drives Phase 2.
$flutterExe = Get-ToolPath 'flutter'
if ($flutterExe -eq '') {
    if ($SkipFlutterBuild) {
        Write-Warn 'flutter not on PATH - fine, -SkipFlutterBuild was requested.'
    } else {
        Stop-WithError -Message 'flutter was not found on PATH.' -Hints @(
            'Install Flutter and add its bin folder to PATH, then re-run.',
            'Or run with -SkipFlutterBuild to do the native DLL half only.'
        )
    }
} else {
    Write-Ok "flutter: $flutterExe"
}

if ($CfaSampleDng -ne '' -and -not (Test-Path -LiteralPath $CfaSampleDng)) {
    Stop-WithError -Message "-CfaSampleDng file not found: $CfaSampleDng"
}

# ---------------------------------------------------------------------------
# Phase 0b - Halide v21 distribution (runbook S1 last row / W1)
# ---------------------------------------------------------------------------
Write-Phase 'Phase 0b: Halide v21 distribution'

# The Halide dist is ~500MB of binaries and is deliberately NOT in git (it was
# removed from history), so the zip cannot carry it - it must be fetched here.
# native/CMakeLists.txt does find_package(Halide REQUIRED) against
# third_party/halide, and the Windows dist ships lib/Halide.lib.
$HalideDir = Join-Path $NativeDir 'third_party\halide'
$HalideLib = Join-Path $HalideDir 'lib\Halide.lib'
if (Test-Path -LiteralPath $HalideLib) {
    Write-Ok "already present: $HalideDir"
} else {
    Write-Step "downloading $($script:HalideAsset)"
    Write-Step "from $($script:HalideUrl)"
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("halide21_" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $zipPath = Join-Path $tempRoot $script:HalideAsset
        try {
            # PowerShell 5.1 defaults to TLS 1.0, which github.com refuses.
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        } catch {
            Write-Warn 'could not force TLS 1.2 - continuing with the default protocol set.'
        }
        $previousProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $script:HalideUrl -OutFile $zipPath -UseBasicParsing
        } catch {
            Stop-WithError -Message "download of $($script:HalideAsset) failed: $($_.Exception.Message)" -Hints @(
                "Download it manually from $($script:HalideUrl)",
                "Extract it so that $HalideLib exists (hoist the archive's single top-level folder), then re-run.",
                'Runbook S1 documents this manual path as the supported workaround.'
            )
        } finally {
            $ProgressPreference = $previousProgress
        }
        $stageDir = Join-Path $tempRoot 'x'
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $stageDir -Force
        $top = Get-ChildItem -LiteralPath $stageDir -Directory | Select-Object -First 1
        if ($null -eq $top) {
            Stop-WithError -Message "unexpected archive layout in $($script:HalideAsset) (no top-level folder)."
        }
        New-Item -ItemType Directory -Path $HalideDir -Force | Out-Null
        Copy-Item -Path (Join-Path $top.FullName '*') -Destination $HalideDir -Recurse -Force
        $versionText = @(
            'halide/Halide@v21.0.0',
            'binary_provenance: vendored from https://github.com/halide/Halide/releases/tag/v21.0.0',
            "asset: $($script:HalideAsset)",
            'abi_notes: schedule changes break AOT artifacts; bump requires full regen.'
        ) -join "`r`n"
        Set-Content -LiteralPath (Join-Path $HalideDir 'VERSION') -Value $versionText -Encoding ASCII
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $HalideLib)) {
        Stop-WithError -Message "Halide extraction finished but $HalideLib is still missing."
    }
    Write-Ok "installed: $HalideDir"
}

# ---------------------------------------------------------------------------
# Phase 1 - W12: configure, build, place the DLL (runbook S3 + S4)
# ---------------------------------------------------------------------------
Write-Phase 'Phase 1: W12 - build dng_decoder_native'

# runbook S3, verbatim command pair (run from native/):
#   cmake --preset windows-vulkan
#   cmake --build --preset windows-vulkan --target dng_decoder_native
Invoke-Checked -Exe 'cmake' -ExeArgs @('--preset', 'windows-vulkan') `
    -WorkingDirectory $NativeDir -What 'cmake configure (windows-vulkan)'
Invoke-Checked -Exe 'cmake' -ExeArgs @('--build', '--preset', 'windows-vulkan', '--target', 'dng_decoder_native') `
    -WorkingDirectory $NativeDir -What 'cmake build (dng_decoder_native)'

# runbook S3 - expected artifact: build-windows\dng_decoder_native.dll (no lib prefix).
$BuildDir = Join-Path $NativeDir 'build-windows'
$BuiltDll = Join-Path $BuildDir 'dng_decoder_native.dll'
if (-not (Test-Path -LiteralPath $BuiltDll)) {
    Stop-WithError -Message "build succeeded but $BuiltDll does not exist." -Hints @(
        'Runbook S3 expects exactly this filename (add_library(dng_decoder_native SHARED) on Windows).',
        'Check the Ninja output above for where the shared library was actually written.'
    )
}
Write-Ok "built: $BuiltDll"

# runbook S4 - the DLL is only "good" once the native colour gate passes on this
# machine. test_cfa_color needs a real blue-sky DNG, which is not shipped in the
# zip, so it runs only when -CfaSampleDng is supplied.
if ($CfaSampleDng -ne '') {
    Invoke-Checked -Exe 'cmake' -ExeArgs @('--build', '--preset', 'windows-vulkan', '--target', 'test_cfa_color') `
        -WorkingDirectory $NativeDir -What 'cmake build (test_cfa_color)'
    $cfaExe = Join-Path $BuildDir 'test_cfa_color.exe'
    if (-not (Test-Path -LiteralPath $cfaExe)) {
        Stop-WithError -Message "test_cfa_color.exe not found at $cfaExe"
    }
    Invoke-Checked -Exe $cfaExe -ExeArgs @($CfaSampleDng, '--expect-blue-sky') `
        -WorkingDirectory $BuildDir -What 'test_cfa_color colour gate'
} else {
    Write-Warn 'colour gate skipped: no -CfaSampleDng given.'
    Write-Step 'Runbook S4 requires test_cfa_color (blue-sky B >> R) to pass before the DLL is trusted.'
    Write-Step 'To run it later:'
    Write-Step "  cmake --build --preset windows-vulkan --target test_cfa_color   (from $NativeDir)"
    Write-Step "  $BuildDir\test_cfa_color.exe <blue-sky.dng> --expect-blue-sky"
}

# runbook S4 - copy the DLL into the packaging-only FFI plugin folder. Nothing
# else from build-windows\ is published. Note: dng_processor_ffi/windows/
# CMakeLists.txt reads exactly this path via dng_processor_ffi_bundled_libraries;
# do not edit that file, just put the DLL here.
New-Item -ItemType Directory -Path $FfiLibDir -Force | Out-Null
Copy-Item -LiteralPath $BuiltDll -Destination $FfiLibDir -Force
$PlacedDll = Join-Path $FfiLibDir 'dng_decoder_native.dll'
if (-not (Test-Path -LiteralPath $PlacedDll)) {
    Stop-WithError -Message "copy to $FfiLibDir did not produce dng_decoder_native.dll"
}
Write-Ok "placed: $PlacedDll"
Write-Step 'This extracted tree is not a git checkout (the zip carries source only),'
Write-Step 'so the runbook S4 "git add / git rm .gitkeep / git commit" step cannot run here.'
Write-Step 'Copy this DLL back to the flutter_dng_decoder repo and commit it there per runbook S4.'

# ---------------------------------------------------------------------------
# Phase 2 - W14: end-to-end Halcyon build (runbook S5)
# ---------------------------------------------------------------------------
if ($SkipFlutterBuild) {
    Write-Phase 'Phase 2: W14 - skipped (-SkipFlutterBuild)'
} else {
    Write-Phase 'Phase 2: W14 - flutter build windows'

    # runbook S5, verbatim:
    #   cd Halcyon
    #   flutter pub get
    #   flutter build windows --release
    Invoke-Checked -Exe 'flutter' -ExeArgs @('pub', 'get') `
        -WorkingDirectory $HalcyonDir -What 'flutter pub get'
    Invoke-Checked -Exe 'flutter' -ExeArgs @('build', 'windows', '--release') `
        -WorkingDirectory $HalcyonDir -What 'flutter build windows --release'

    # runbook S5 - the DLL must sit next to the runner exe in the Release folder.
    $ReleaseDir  = Join-Path $HalcyonDir 'build\windows\x64\runner\Release'
    $BundledDll  = Join-Path $ReleaseDir 'dng_decoder_native.dll'
    if (-not (Test-Path -LiteralPath $BundledDll)) {
        # runbook S5 diagnostics, in the order it prescribes. Do NOT hand-copy
        # the DLL as a workaround - that hides a real packaging bug.
        Write-Host ''
        Write-Host '    Packaging check FAILED - running the runbook S5 diagnostics:'
        $genPlugins = Join-Path $HalcyonDir 'windows\flutter\generated_plugins.cmake'
        if (Test-Path -LiteralPath $genPlugins) {
            $genText = Get-Content -LiteralPath $genPlugins -Raw
            if ($genText -match 'dng_processor_ffi') {
                Write-Host '    1. generated_plugins.cmake DOES list dng_processor_ffi (plugin was discovered).'
            } else {
                Write-Host '    1. generated_plugins.cmake does NOT list dng_processor_ffi.'
                Write-Host '       -> flutter pub get did not pick up the plugin declaration (W10).'
                Write-Host '       -> try: flutter clean, then re-run this script (stale generated files).'
            }
        } else {
            Write-Host "    1. $genPlugins is missing entirely."
        }
        Write-Host "    2. Check that $PlacedDll existed at configure time (it does now - a stale"
        Write-Host '       CMake cache from before Phase 1 can still hold the empty value). Try:'
        Write-Host '       flutter clean, then re-run this script.'
        Write-Host '       Then grep the CMake log for dng_processor_ffi_bundled_libraries; if it'
        Write-Host '       resolves to empty, that is the silent-failure mode documented in'
        Write-Host '       dng_processor_ffi/windows/CMakeLists.txt.'
        Stop-WithError -Message "dng_decoder_native.dll is not in $ReleaseDir" -Hints @(
            'Runbook S5: do not manually copy the DLL as a workaround - it would hide a real packaging bug.'
        )
    }
    Write-Ok "bundled: $BundledDll"

    # The runner exe name comes from Halcyon/windows/CMakeLists.txt BINARY_NAME
    # (currently photo_selector_flutter); runbook S5 calls it halcyon.exe.
    $exeFiles = @(Get-ChildItem -LiteralPath $ReleaseDir -Filter '*.exe' -ErrorAction SilentlyContinue)
    if ($exeFiles.Count -eq 0) {
        Write-Warn "no .exe found in $ReleaseDir - the DLL is there but the runner is not."
    } else {
        foreach ($exe in $exeFiles) {
            Write-Ok "runner exe alongside it: $($exe.Name)"
        }
    }

    # ---------------------------------------------------------------------
    # Phase 3 - manual verification protocol (runbook S5 + S6)
    # ---------------------------------------------------------------------
    Write-Phase 'Phase 3: manual verification (this script does not automate it)'
    Write-Host ''
    Write-Host '    Runbook S5 - correctness:'
    Write-Host "      1. Launch $ReleaseDir\<runner>.exe"
    Write-Host '      2. Open DNG files from local_data\photo_samples\DNG\ ONLY.'
    Write-Host '         NOTE: photo samples are not shipped in this zip - copy them over yourself.'
    Write-Host '      3. Confirm DngResult.errorCode == 0 for each sample.'
    Write-Host '      4. Confirm there is no RAW_UNSUPPORTED / MISSING_PLUGIN fallback to the Dart'
    Write-Host '         preview path - a silent fallback would look like success while native decode failed.'
    Write-Host ''
    Write-Host '    Runbook S6 - timing (the 1-second gate):'
    Write-Host '      1. Pick 3-5 representative DNG samples.'
    Write-Host '      2. COLD-LAUNCH the exe for every "first decode" measurement (fresh process each time).'
    Write-Host '      3. Record wall-clock "decode requested" -> "decode complete" (decodeMs + processMs).'
    Write-Host '      4. HARD GATE: if any first decode exceeds 1000 ms, STOP. Do not average it away,'
    Write-Host '         do not retry until fast, do not report a warm number. Record: exact ms, which'
    Write-Host '         sample, GPU model + driver version (vulkaninfo), and whether a second cold'
    Write-Host '         launch shows the same first-decode latency.'
    Write-Host '      5. Then, in the SAME warm process, decode 5-10 more samples and record'
    Write-Host '         min/median/max separately (these should be fast, ~110 ms macOS Metal baseline).'
    Write-Host '      6. If the gate is breached: write a handover document first. Do NOT start the'
    Write-Host '         VkPipelineCache persistence work directly (runbook S6).'
    Write-Host '      7. If the gate passes: record the numbers in runbook section 7 "Results".'
}

Write-Host ''
Write-Host '============================================================'
if ($script:WarningCount -gt 0) {
    Write-Host " DONE with $($script:WarningCount) warning(s) - review the [warn] lines above."
} else {
    Write-Host ' DONE - no warnings.'
}
Write-Host '============================================================'
exit 0
