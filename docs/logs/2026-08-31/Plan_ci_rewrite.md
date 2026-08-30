# Halcyon unified Python CI scripts — Implementation Plan

> **For agentic workers:** implement this plan task-by-task via an agent team, one member per
> work package. Steps use checkbox (`- [ ]`) syntax for tracking. Report
> `READY_FOR_SIGNOFF` with evidence; do not self-close tickets.

**Goal:** Replace the build/test/package/verify logic currently inlined in
`.github/workflows/ci.yml` and `.github/workflows/release.yml` with one cross-platform Python
entry point, `scripts/ci.py`, so that every job body is a single `python3 scripts/ci.py …` line
and the same command is runnable on a laptop.

**Architecture:** `scripts/ci.py` is argparse dispatch only. All logic lives in `scripts/ci/`:
`targets.py` (pure data — the only place a per-platform fact is stated), `run.py` (list-argv
`subprocess` wrapper, `shell=False`, RC self-capture), `phases.py` (provision/verify/build/
package/release-preflight, containing **no** `if target == …`), `assertions.py` (the R-7
capability suite), `report.py` (artifact logs + machine-checkable summary). `scripts/build_apps.py`
remains the single build entry point and is **called, never reimplemented**.

**Tech Stack:** Python 3 stdlib only (`argparse`, `subprocess`, `pathlib`, `shutil`, `zipfile`,
`tarfile`, `hashlib`, `json`, `unittest`); Flutter 3.44.6; GitHub Actions.

---

## 0. Verbatim contract quote

Reproduced verbatim from `docs/logs/2026-08-31/Contract_ci_rewrite.md:3-24`. Re-paste this block
at every round's kickoff; do not paraphrase.

> ## 終態（一句話）
> Halcyon 的 CI 建置流程由一套全平台統一的 Python CI scripts 驅動（取代分散於 YAML 內聯步驟與零散腳本的邏輯），所有平台 CI 全綠並 merge 回 main。

> ## 驗收條件（逐條）
> - AC1. Spec 檔存在，逐條對照 ceyx `Requirements_ci_rewrite.md` R-1~R-8 聲明「適用於 Halcyon / 不適用＋理由」，且涵蓋 Halcyon 特有約束（sibling ceyx checkout、ceyx_release_pin、build_apps.py 單一入口）。
> - AC2. Plan 檔存在，含分階段步驟、每步驗證方式、檔案清單。
> - AC3. 統一 Python CI scripts 存在；workflows 中除 checkout/setup-flutter/cache 等環境動作外，建置/測試/打包/驗證邏輯皆經該 scripts；Windows job 無 `shell: bash` 建置步驟。
> - AC4. 所有平台 CI jobs 於工作分支上全綠（`gh run list` conclusion==success，判空顯式比對字串）。
> - AC5. merge 回 main 後，main 上的 CI run 全綠（合併後驗證是獨立閘，08-16 家族）。
> - AC6. 本機 `flutter analyze` 0 issues、`flutter test -j 1` 全綠（機械證據：exit code artifact 內自捕 RC=$?）。

Out-of-scope, verbatim (`Contract_ci_rewrite.md:12-16`):

> - ceyx repo 本身的 build rewrite（另有其契約）。
> - 任何第三方函式庫版本釘選變更（載體中立）。
> - app 程式碼行為變更（僅允許 CI/build 腳本所需的改動）。
> - release tag 實發（release.yml 的驗證以 CI 可驗證的方式進行，不實際發版）。

## Global Constraints

Every work package's requirements implicitly include this section.

- **G-1** No `shell=True` anywhere under `scripts/ci/` or in `scripts/ci.py`. Ever. (Spec §4.6.1)
- **G-2** Exit codes come only from `subprocess.CompletedProcess.returncode`. Never a shell
  pipeline, never `${PIPESTATUS[n]}`, never a harness notification. (Spec §4.6.2)
- **G-3** No `| grep` in any argv. Capture tool output to `str` and match in Python.
  (Spec §4.6.3 — `nm | grep -q` inverts under `pipefail`.)
- **G-4** Every phase writes `build/ci-logs/<target>-<phase>.txt` whose **last line is `RC=<n>`**,
  written by the producing process. (Spec §4.6.4)
- **G-5** No file under `scripts/ci/` other than `targets.py` may contain `if target ==`,
  `if platform ==`, `if sys.platform ==` for build/package/provision branching. Per-platform facts
  are dict entries in `targets.py`. (Spec §4.2, R-1c)
- **G-6** No edits to `scripts/ceyx_release_pin.json` (values or prose), `pubspec.lock`,
  `flutter-version: '3.44.6'`, any `build_apps.py` flag default, or any `lib/` source. 載體中立.
- **G-7** `ci.py` never passes `--no-colour-gate` to `build_apps.py`, and propagates
  `build_apps.py`'s exit code 2 as a failure. (Spec §5.3)
- **G-8** Paths are built with `pathlib` and passed as `os.fspath(Path(...).resolve())`. No
  string-concatenated paths in any rendered argv. (Spec §4.7)
- **G-9** Both `actions/checkout@v4` steps (Halcyon + `jhangyu/ceyx`) and
  `defaults: run: working-directory: Halcyon` stay in every job, and the "don't simplify this
  back" comments (`ci.yml:1-4`, `release.yml:3-6`) are carried over **verbatim**. (Spec §5.1)
- **G-10** `gh run list --json conclusion` returns `""` (empty string), not `null`, for
  in-progress runs. Any status check compares against the literal string `"success"`. (AC4)
- **G-11** Python stdlib only. No new pip/pub dependency.

### Rulings already made — do not reopen

- **OQ-1 → option (c) with (b) as the recorded fallback.** `H-SIZED-SYMBOL` is measured by a
  **functional FFI probe**: `DynamicLibrary.open` the shipped library and look up
  `dng_decode_and_process_sized`. The `nm`/`dumpbin` symbol-table instrument is **excluded from
  `valid_on` for Windows** until a red state is demonstrated on a real Windows runner.
- **OQ-2 → deferred.** `H-BUNDLE-RUNS` ("packaged app launches") is **not** implemented this
  round. Recorded as a known gap in §7 and as `PL-7`.
- **OQ-3 → unpinned.** The `jhangyu/ceyx` checkout stays without a `ref:`. Adding one is itself a
  pin change and 載體中立 forbids it this round.
- **OQ-4 → collapse.** `release.yml`'s three jobs become one matrix with `fail-fast: false`.

---

## 1. File structure

| Path | Owner WP | Status | Responsibility |
|---|---|---|---|
| `scripts/ci.py` | A | create | argparse dispatch only; repo-root resolution; Windows-interpreter guard |
| `scripts/ci/__init__.py` | A | create | empty marker |
| `scripts/ci/run.py` | A | create | `run()` / `run_logged()` — list argv, `shell=False`, RC self-capture |
| `scripts/ci/report.py` | A | create | log file writing, `RC=` trailer, `CI-SUMMARY:` line |
| `scripts/ci/targets.py` | A | create | **data only**: per-target build flags, provision steps, artifact paths, archive names |
| `scripts/ci/phases.py` | B | create | `provision` / `verify` / `build` / `package` / `release_preflight` |
| `scripts/ci/assertions.py` | C | create | R-7 assertion records + runner; wraps `check_dng_ffi_artifacts.py` logic |
| `scripts/ci/probe/ffi_probe.dart` | C | create | functional FFI probe for `H-SIZED-SYMBOL` (OQ-1 ruling c) |
| `scripts/dng_ffi_artifacts.json` | C | modify | add R-7 fields per platform entry |
| `scripts/check_dng_ffi_artifacts.py` | C | modify (additive) | expose its symbol check as an importable function; keep CLI behaviour |
| `.github/workflows/ci.yml` | D | rewrite | matrix + `fail-fast: false`; every `run:` is one `ci.py` line |
| `.github/workflows/release.yml` | D | rewrite | one matrix over `(os,target)`; `workflow_dispatch` dry-run path |
| `scripts/ci/tests/__init__.py` | E | create | marker |
| `scripts/ci/tests/test_render.py` | E | create | golden argv per target + Windows path lints |
| `scripts/ci/tests/test_policy.py` | E | create | mechanical AC3/R-5/G-1/G-5 greps over the repo |
| `scripts/ci/tests/golden/<target>.txt` | E | create | frozen expected argv |

**Not touched (restated):** `scripts/build_apps.py`, `scripts/ceyx_release_pin.json`,
`scripts/package_windows.sh`, `scripts/gen_windows_associations.dart`, `scripts/focus_forensics.sh`,
everything under `lib/`, `test/`, `pubspec.*`.

---

## 2. Frozen interfaces (Stage-1 skeleton — all packages code against these)

WP-A lands these signatures first; B/C/D/E are written against this block and may start as soon
as A's files exist as stubs.

```python
# scripts/ci/run.py
from dataclasses import dataclass
from pathlib import Path

@dataclass
class RunResult:
    argv: list[str]
    returncode: int
    stdout: str
    stderr: str

def run(argv: list[str], cwd: Path | None = None, env: dict | None = None) -> RunResult:
    """subprocess.run(argv, shell=False, capture_output=True, text=True). Never raises on
    non-zero. G-1/G-2/G-3."""

def run_logged(argv: list[str], log_path: Path, cwd: Path | None = None) -> RunResult:
    """run() then report.write_log(log_path, header=argv, body=stdout+stderr, rc=returncode).
    G-4."""
```

```python
# scripts/ci/report.py
from pathlib import Path

def log_path_for(repo_root: Path, target: str, phase: str) -> Path:
    """repo_root / 'build' / 'ci-logs' / f'{target}-{phase}.txt'"""

def write_log(path: Path, header: str, body: str, rc: int) -> None:
    """Creates parents; writes header, body, then a final line exactly 'RC=<rc>'."""

def summary(target: str, phases: int, failed: int) -> str:
    """Returns exactly f'CI-SUMMARY: {target} phases={phases} failed={failed}'"""

def skip_line(assertion_id: str, reason: str) -> str:
    """Returns exactly f'SKIP: {assertion_id} — {reason}'"""
```

```python
# scripts/ci/targets.py   (DATA ONLY — no function containing platform logic)
TARGETS: dict[str, dict] = {
  "macos":       {...}, "windows": {...}, "linux": {...},
  "android-apk": {...}, "web":     {...},
}
# Each entry's keys, exactly:
#   "runs_on":        str          e.g. "macos-14"
#   "build_flags":    list[str]    argv tail appended after ["python3","scripts/build_apps.py",<target>]
#   "provision":      list[list[str]]  argv list, may be []
#   "artifact_kind":  str          one of "app_bundle" | "dir" | "glob_dir"
#   "artifact_path":  str          repo-root-relative; may contain one "*" for glob_dir
#   "archive_name":   str          format string with {version}, e.g. "Halcyon-macos-arm64-{version}.zip"
#   "archive_format": str          "zip" | "gztar"
#   "assertions":     list[str]    assertion ids from assertions.SUITE that apply
#   "pin_platform":   str | None   key into ceyx_release_pin.json["assets"], or None

def target_names() -> list[str]: ...
def spec(target: str) -> dict:
    """Returns TARGETS[target]; raises KeyError with a named message listing valid targets."""
```

```python
# scripts/ci/phases.py
from pathlib import Path

def provision(repo_root: Path, target: str) -> int: ...
def verify(repo_root: Path) -> int:
    """pub get -> analyze -> test -j 1. All three ALWAYS run; failures accumulate; one non-zero
    exit at the end. R-4."""
def build(repo_root: Path, target: str, mode: str = "release") -> int:
    """Thin delegator to scripts/build_apps.py. Exit code 2 is a failure (G-7)."""
def package(repo_root: Path, target: str, version: str) -> int:
    """Resolves artifact_path, produces archive_name via zipfile/tarfile. One implementation."""
def release_preflight(repo_root: Path, version: str, targets: list[str]) -> int:
    """Asserts each expected archive exists at the exact path action-gh-release globs; prints it."""
def print_plan(repo_root: Path, target: str) -> int:
    """Prints rendered argv for provision/build/package without executing. Exit 0."""
```

```python
# scripts/ci/assertions.py
from dataclasses import dataclass
from pathlib import Path

@dataclass(frozen=True)
class Assertion:
    id: str
    measures: str
    valid_on: tuple[str, ...]
    why_valid: str
    red_state: str
    expected: str

SUITE: dict[str, Assertion]     # keys: H-ARCH, H-DECODER-PRESENT, H-DECODER-DEPS,
                                #       H-DECODER-HASH, H-SIZED-SYMBOL

def validate_suite() -> None:
    """Raises ValueError naming any assertion missing one of the five mandatory fields."""

def run_suite(repo_root: Path, target: str) -> int:
    """Runs SUITE entries listed in targets.spec(target)['assertions'].
    A skip on the artefact's OWN platform is a FAILURE (Spec §4.5).
    Prints one report.skip_line() per legitimate skip and states the skipped count."""
```

```python
# scripts/ci.py — CLI surface (frozen; workflows depend on these exact strings)
python3 scripts/ci.py provision           --target T
python3 scripts/ci.py verify
python3 scripts/ci.py build               --target T [--mode release]
python3 scripts/ci.py assert-capabilities --target T
python3 scripts/ci.py package             --target T --version V
python3 scripts/ci.py release-preflight   --version V --target T [--target T2 ...]
python3 scripts/ci.py --print-plan        --target T
```

---

## 3. Work packages

Five packages. **WP-A is serial and first** — the shared state is the module boundary and the
frozen signatures above; B/C/D/E all import from it. Once A's files exist (even as stubs with
correct signatures), **B, C, D, E run fully in parallel** — their owned file sets are mutually
exclusive, with one declared exception handled in WP-C.

```
        WP-A (serial, first)
          │
    ┌─────┼─────┬─────┐
   WP-B  WP-C  WP-D  WP-E     (parallel)
    └─────┴─────┴─────┘
          │
       WP-F (serial, last: integration + red-state demo + local gate)
```

---

### WP-A — Core scaffolding, data, and the run/report primitives

**Files (owned exclusively):**
- Create: `scripts/ci.py`
- Create: `scripts/ci/__init__.py`
- Create: `scripts/ci/run.py`
- Create: `scripts/ci/report.py`
- Create: `scripts/ci/targets.py`

**Interfaces:** Produces everything in §2 for `run.py`, `report.py`, `targets.py`, and the CLI
surface. Consumes nothing.

**Behavior:**
- `ci.py` resolves the repo root from **its own on-disk location** (`Path(__file__).resolve().parent.parent`),
  the pattern `check_dng_ffi_artifacts.py:98-103` already uses — so behaviour is identical
  regardless of invocation cwd.
- `ci.py` fails at startup with the exact named error
  `ERROR: sibling ceyx checkout not found at <resolved path>` when `<repo_root>/../ceyx/plugin`
  is absent, for every subcommand except `--print-plan`. Spec §5.1 calls this the single most
  likely first-round CI failure mode; an opaque `pub get` resolution error must not be what CI shows.
- Windows interpreter guard (Spec §4.7.3): on `os.name == "nt"`, fail if
  `pathlib.Path(sys.executable).drive` is empty **or** `"/usr/bin" in sys.executable` — an MSYS
  Python would reintroduce the whole path-mangling family through the back door.
- `run()` never raises on a non-zero child; the caller decides. `run()` never inherits a shell.
- `targets.py` `build_flags` are copied **byte-for-byte** from today's workflows:
  `windows -> ["--fetch-native"]` (rationale `release.yml:96-101`), all others `[]`.
  `provision`: `linux -> [["sudo","apt-get","update"],["sudo","apt-get","install","-y","ninja-build","libgtk-3-dev"]]`,
  `macos -> [["pod","install"]]` run in `<repo_root>/macos`, others `[]`.
  `artifact_path`: `macos -> build/macos/Build/Products/Release/Halcyon.app`,
  `windows -> build/windows/x64/runner/Release`, `linux -> build/linux/*/release/bundle`
  (glob_dir — the arch segment is host-dependent, `build_apps.py:1748-1751`).
  `archive_name`: `Halcyon-macos-arm64-{version}.zip`, `Halcyon-windows-x64-{version}.zip`,
  `Halcyon-linux-x64-{version}.tar.gz` — identical to `release.yml:66/105/144`.

**Constraints:** G-1..G-11. `ci.py` contains dispatch only — if a function in `ci.py` is longer
than 15 lines it belongs in `phases.py`. `targets.py` contains no `import subprocess`.

**Acceptance criteria:**
- [ ] `python3 scripts/ci.py --help` exits 0 and its output contains all seven subcommand names.
- [ ] `python3 -c "import sys; sys.path.insert(0,'scripts'); import ci.targets as t; print(sorted(t.target_names()))"`
      prints `['android-apk', 'linux', 'macos', 'web', 'windows']`.
- [ ] `grep -rn "shell=True" scripts/ci.py scripts/ci/` returns no lines (exit 1).
- [ ] `grep -rn "if target ==\|if platform ==\|if sys.platform ==" scripts/ci/ --include=*.py | grep -v targets.py`
      returns no lines.
- [ ] Renaming `../ceyx` away and running `python3 scripts/ci.py verify` prints a line containing
      `sibling ceyx checkout not found` and exits non-zero.

**Steps:**

- [ ] **A1: Create the package skeleton with correct signatures and `NotImplementedError` bodies**
      for every function in §2 belonging to `run.py`/`report.py`/`targets.py`, plus a complete
      `argparse` tree in `ci.py`. Commit immediately — this unblocks B/C/D/E.
      `git add scripts/ci.py scripts/ci/__init__.py scripts/ci/run.py scripts/ci/report.py scripts/ci/targets.py`
      `git commit -- scripts/ci.py scripts/ci/ -m "feat(ci): scaffold scripts/ci package with frozen interfaces"`
      Verify: `python3 scripts/ci.py --help` exits 0.
- [ ] **A2: Fill `targets.py`** with the five dict entries above, transcribing flags from
      `ci.yml:125`, `release.yml:60/102/138` and paths from `build_apps.py:1730-1752`.
      Verify: the `target_names()` acceptance command prints the exact expected list.
- [ ] **A3: Implement `run.py`** — `subprocess.run(argv, shell=False, capture_output=True, text=True, cwd=cwd, env=env)`.
      Verify: `python3 -c "...; print(run(['python3','-c','import sys;sys.exit(3)']).returncode)"` prints `3`.
- [ ] **A4: Implement `report.py`** — `write_log` must write the `RC=` line last, with no trailing
      blank line after it.
      Verify: after A3's call wrapped in `run_logged`, `tail -n 1 build/ci-logs/x-y.txt` is exactly `RC=3`.
- [ ] **A5: Implement `ci.py`'s repo-root resolution, ceyx-sibling guard, and Windows-interpreter
      guard.** Verify with the two guard acceptance commands above.
- [ ] **A6: Commit** `git commit -- scripts/ci.py scripts/ci/ -m "feat(ci): implement run/report primitives and target data"`

---

### WP-B — Phases: provision / verify / build / package / release-preflight / print-plan

**Files (owned exclusively):**
- Create: `scripts/ci/phases.py`

**Interfaces:** Consumes `run.run`, `run.run_logged`, `report.log_path_for`, `report.summary`,
`targets.spec`, `targets.target_names` (§2). Produces the six `phases.*` functions in §2, called
by `ci.py`'s dispatch (WP-A wires the call sites in A1's stub tree).

**Behavior:**
- `verify()` runs **all three** phases regardless of failure (`flutter pub get`,
  `flutter analyze`, `flutter test -j 1`), accumulates failed phase names, prints
  `report.summary("host", 3, len(failed))` and returns `0` iff `failed` is empty. This is R-4's
  transferable form: an analyze failure must not hide a test failure.
- `build()` renders `["python3", "scripts/build_apps.py", target, *spec["build_flags"]]` and
  execs it via `run_logged`. It does **not** parse `build_apps.py` internals, does not bypass it
  for any target, and never appends `--no-colour-gate`. Exit code `2` (colour-gate refusal) is
  propagated as a failure, not swallowed (G-7).
- `package()` is **one implementation for three platforms**, replacing `ditto` (`release.yml:63-66`),
  `Compress-Archive` (`:105`) and `find`+`tar` (`:141-144`):
  - resolve `artifact_path`; for `glob_dir`, `sorted(repo_root.glob(pattern))[0]`, and if the
    glob matches nothing, fail with `ERROR: no artifact matched <pattern>` (the behaviour
    `release.yml:143`'s `test -n` provides today);
  - `zip` → `zipfile.ZipFile(..., ZIP_DEFLATED)` writing paths **relative to the artifact's
    parent** for `app_bundle` (equivalent to `ditto --keepParent`) and relative to the directory
    itself for `dir` (equivalent to `Compress-Archive -Path <dir>/*`);
  - `gztar` → `tarfile.open(..., "w:gz")` with `arcname="bundle"`, matching
    `tar -C "$(dirname "$bundle_dir")" bundle`.
  The archive lands at `<repo_root>/<archive_name.format(version=version)>` — the exact path
  `action-gh-release` globs as `Halcyon/<name>`.
- `release_preflight()` checks each requested target's archive exists at that exact path, prints
  one line per archive (`PREFLIGHT-OK: <path> <bytes> bytes`), and returns non-zero naming every
  missing one. This is the contract's "release.yml 的驗證以 CI 可驗證的方式進行，不實際發版".
- `print_plan()` prints, per phase, `PLAN <phase>: <shlex-free joined argv list repr>` and exits 0
  **without executing anything** — the whole point is rendering Windows argv from a macOS laptop.

**Constraints:** G-1..G-11, and specifically **G-5: `phases.py` must contain zero
`if target ==`.** Every platform difference is read from `targets.spec(target)`.

**Acceptance criteria:**
- [ ] `python3 scripts/ci.py --print-plan --target windows` exits 0, prints a line containing
      `build_apps.py` and `--fetch-native`, and executes nothing (no `build/` mtime change).
- [ ] `python3 scripts/ci.py --print-plan --target macos` output does **not** contain `--fetch-native`.
- [ ] `grep -c "if target ==" scripts/ci/phases.py` prints `0`.
- [ ] With a hand-made `build/macos/Build/Products/Release/Halcyon.app/` containing one file,
      `python3 scripts/ci.py package --target macos --version v0.0.0-test` produces
      `Halcyon-macos-arm64-v0.0.0-test.zip` whose `unzip -l` listing has every entry prefixed
      `Halcyon.app/`.
- [ ] `python3 scripts/ci.py release-preflight --version v0.0.0-test --target macos` exits 0 and
      prints a `PREFLIGHT-OK:` line; deleting the zip makes it exit non-zero naming the path.
- [ ] `python3 scripts/ci.py verify` prints exactly one line matching `^CI-SUMMARY: ` and its
      `phases=3`.

**Steps:**

- [ ] **B1: Write the failing golden test for `--print-plan`** in coordination with WP-E: WP-E
      owns the test file, WP-B owns the renderer. Run `python3 -m unittest discover -s scripts/ci/tests -v`
      and confirm it FAILS with `NotImplementedError`.
- [ ] **B2: Implement `build()` + `print_plan()`** (rendering shared: `print_plan` prints what
      `build` would exec, from the same function, so a flag can never drift between them — that
      shared renderer is the design's whole defence).
      Verify: the two `--print-plan` acceptance commands.
- [ ] **B3: Implement `verify()` with accumulation.** Verify: temporarily introduce an analyze
      error in a scratch copy and confirm the test phase still runs (log file
      `build/ci-logs/host-test.txt` exists) and the summary reports `failed=1`.
- [ ] **B4: Implement `provision()`** — iterate `spec["provision"]`, `run_logged` each, accumulate.
      macOS's `pod install` runs with `cwd=repo_root/"macos"`.
      Verify: `python3 scripts/ci.py --print-plan --target linux` shows both apt argv lists.
- [ ] **B5: Implement `package()`** for all three formats. Verify: the `unzip -l` acceptance check
      plus a Linux-shaped `gztar` case using a fake `build/linux/x64/release/bundle/`.
- [ ] **B6: Implement `release_preflight()`.** Verify: both acceptance directions (present → 0,
      deleted → non-zero naming the path).
- [ ] **B7: Commit** `git commit -- scripts/ci/phases.py -m "feat(ci): implement provision/verify/build/package phases"`

---

### WP-C — R-7 capability assertions

**Files (owned exclusively):**
- Create: `scripts/ci/assertions.py`
- Create: `scripts/ci/probe/ffi_probe.dart`
- Modify: `scripts/dng_ffi_artifacts.json`
- Modify: `scripts/check_dng_ffi_artifacts.py` (additive only — see the declared exception below)

**Declared exception to exclusive ownership:** `check_dng_ffi_artifacts.py` is a pre-existing file.
WP-C's change to it is **strictly additive**: extract the body of `check_symbol` unchanged and
export it, so `assertions.py` can `from check_dng_ffi_artifacts import check_symbol`. Its CLI
behaviour, output strings, and exit codes must be byte-identical afterwards. No other package
touches this file.

**Interfaces:** Consumes `run.run`, `report.skip_line`, `targets.spec`. Produces `Assertion`,
`SUITE`, `validate_suite()`, `run_suite()` (§2).

**Behavior:**

Each `Assertion` carries all five mandatory fields; `validate_suite()` **rejects** any record
missing one, and is called at the top of `run_suite()` so an under-specified assertion can never
run. The suite, per Spec §4.5 and the OQ-1 ruling:

| id | measures | method | valid_on | red_state recipe |
|---|---|---|---|---|
| `H-ARCH` | the app binary's machine architecture equals the target's declared arch | `lipo -archs` (Mach-O) / ELF `e_machine` read with `struct` / PE `IMAGE_FILE_HEADER.Machine` read with `struct` — all read in Python, no `\|grep` (G-3) | macos, linux, windows | point the assertion at a known-wrong-arch binary and confirm it fails |
| `H-DECODER-PRESENT` | the ceyx decoder library exists **inside the produced archive**, at the path the app will `DynamicLibrary.open` | archive inventory via `zipfile`/`tarfile` — never the build tree | macos, linux, windows | remove the library from a staging copy before packaging; assertion must fail |
| `H-DECODER-DEPS` | on Windows all three DLLs (`dng_decoder_native.dll`, `heif.dll`, `libde265.dll`) are in the archive together | archive inventory vs. `ceyx_release_pin.json["assets"]["windows"]["libraries"]` **read as data** (R-1a/R-1c — never a hardcoded list) | windows | delete `heif.dll` from a staging copy; assertion must fail naming it |
| `H-DECODER-HASH` | each placed ceyx library's SHA-256 equals the pin | `hashlib.sha256` over the archive member's bytes | linux, windows | flip one byte in a staging copy; assertion must fail |
| `H-SIZED-SYMBOL` | `dng_decode_and_process_sized` is **reachable** in the shipped decoder | **functional FFI probe** (OQ-1 ruling c): `dart run scripts/ci/probe/ffi_probe.dart <library path>` → `DynamicLibrary.open` + `lookup`, exit 0 on success | macos, linux **and** windows (the probe is format-agnostic, which is exactly why it was chosen) | point the probe at a library built without the symbol, or at a nonexistent path; probe must exit non-zero |

`H-BUNDLE-RUNS` is **not implemented** (OQ-2 ruling). It is recorded in §7 as a known gap.

**The symbol-table instrument is retained only as a `valid_on: ("macos","linux")` secondary
record** — id `H-SIZED-SYMBOL-NM` — precisely because ceyx learned it is valid on Mach-O/ELF by
coincidence of permissive default visibility and structurally invalid on Windows PE. It is
**excluded from Windows** until a red state is demonstrated on a real Windows runner. That
exclusion is written into the record's `why_valid` text, not left implicit.

**Skip semantics (Spec §4.5, 2026-08-25 lesson).** A silently-skipped gate produces a green
report indistinguishable from a full run. Therefore:
- a skip for an assertion whose `valid_on` includes the **current host platform** is a **FAILURE**
  (the tool's absence is an environment defect, not a legitimate skip);
- every legitimate skip prints exactly one `report.skip_line(id, reason)`;
- the final summary states the skipped count.

**Constraints:** G-1..G-11. `assertions.py` reads `ceyx_release_pin.json` and never writes it
(G-6). The FFI probe is a standalone Dart file — it must not be added to `pubspec.yaml`'s
dependencies and must not import any `lib/` code (載體中立: no app behaviour change).

**Acceptance criteria:**
- [ ] `python3 -c "import sys;sys.path.insert(0,'scripts');import ci.assertions as a;a.validate_suite();print(sorted(a.SUITE))"`
      prints `['H-ARCH', 'H-DECODER-DEPS', 'H-DECODER-HASH', 'H-DECODER-PRESENT', 'H-SIZED-SYMBOL', 'H-SIZED-SYMBOL-NM']`.
- [ ] Deleting any one of the five fields from any record makes `validate_suite()` raise a
      `ValueError` naming that record and that field (demonstrate once, in a scratch copy).
- [ ] `python3 -c "...; print(a.SUITE['H-SIZED-SYMBOL-NM'].valid_on)"` prints a tuple **not**
      containing `windows`.
- [ ] `python3 scripts/check_dng_ffi_artifacts.py` output is byte-identical before and after WP-C's
      edit (capture to `docs/logs/2026-08-31/ffi-check-before.txt` / `-after.txt`, `diff` them, empty).
- [ ] `python3 scripts/ci.py assert-capabilities --target macos` exits 0 on this machine and prints
      a summary line stating the skipped count.
- [ ] **Red-state demonstration** (delivery requirement, not optional): the `H-DECODER-DEPS` and
      `H-DECODER-HASH` recipes are each executed once against a staging copy, observed RED, and the
      terminal output saved to `docs/logs/2026-08-31/red-state-<id>.txt` with a self-captured
      `RC=` trailer. A gate never seen to fail is not evidence.

**Steps:**

- [ ] **C1: Extend `scripts/dng_ffi_artifacts.json`** — add `measures` / `valid_on` / `why_valid` /
      `red_state` / `expected` to each platform entry. Do not change any existing key.
      Verify: `python3 scripts/check_dng_ffi_artifacts.py` still exits 0 with identical output.
- [ ] **C2: Additive refactor of `check_dng_ffi_artifacts.py`** — no behaviour change.
      Verify: the byte-identical-output acceptance check.
- [ ] **C3: Write `validate_suite()` and the six `Assertion` records first, with `run_suite()`
      raising `NotImplementedError`.** Verify: the `sorted(a.SUITE)` acceptance command, and the
      missing-field `ValueError` demo.
- [ ] **C4: Write `scripts/ci/probe/ffi_probe.dart`:**

```dart
// Functional FFI probe for H-SIZED-SYMBOL (OQ-1 ruling c). Format-agnostic: it
// tests the CAPABILITY (symbol reachable at runtime), not a symbol-table proxy.
// Usage: dart run scripts/ci/probe/ffi_probe.dart <path-to-decoder-library>
import 'dart:ffi';
import 'dart:io';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: ffi_probe.dart <library-path>');
    exit(2);
  }
  final path = args.single;
  try {
    final lib = DynamicLibrary.open(path);
    lib.lookup<NativeFunction<Void Function()>>('dng_decode_and_process_sized');
    stdout.writeln('PROBE-OK: dng_decode_and_process_sized reachable in $path');
    exit(0);
  } catch (e) {
    stderr.writeln('PROBE-FAIL: $path: $e');
    exit(1);
  }
}
```

- [ ] **C5: Run the probe red once** against a nonexistent path:
      `dart run scripts/ci/probe/ffi_probe.dart /nonexistent.dylib; echo RC=$?`
      Expected: `PROBE-FAIL:` on stderr and `RC=1`. Save to `docs/logs/2026-08-31/red-state-H-SIZED-SYMBOL.txt`.
- [ ] **C6: Run the probe green once** against
      `../ceyx/plugin/macos/Libraries/libdng_decoder_native.dylib`. Expected `PROBE-OK:` and `RC=0`.
- [ ] **C7: Implement `run_suite()`** with the skip-is-failure-on-native-platform rule.
      Verify: `assert-capabilities --target macos` acceptance command.
- [ ] **C8: Execute the `H-DECODER-DEPS` and `H-DECODER-HASH` red states** per the acceptance
      criterion and save the artifacts.
- [ ] **C9: Commit** `git commit -- scripts/ci/assertions.py scripts/ci/probe/ scripts/dng_ffi_artifacts.json scripts/check_dng_ffi_artifacts.py docs/logs/2026-08-31/ -m "feat(ci): R-7 capability assertion suite with functional FFI probe"`

---

### WP-D — Workflow rewrite

**Files (owned exclusively):**
- Rewrite: `.github/workflows/ci.yml`
- Rewrite: `.github/workflows/release.yml`

**Interfaces:** Consumes only the frozen CLI surface in §2. Produces nothing other packages import.

**Behavior:**

`ci.yml` — the three copy-pasted analyze/test jobs (`ci.yml:18-97`) collapse into one matrix:

```yaml
jobs:
  verify:
    name: Analyze & Test (${{ matrix.os }})
    strategy:
      fail-fast: false        # NOT continue-on-error: a job still fails when it fails;
                              # this only lets sibling OS jobs finish. See the header comment.
      matrix:
        os: [macos-14, windows-latest, ubuntu-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
        with: {path: Halcyon}
      - uses: actions/checkout@v4
        with: {repository: jhangyu/ceyx, path: ceyx}
      - uses: subosito/flutter-action@v2
        with: {flutter-version: '3.44.6', channel: 'stable', cache: true}
      - run: python3 scripts/ci.py verify
```

The macOS build job keeps its own job (it is a different deliverable, not a matrix leg) and becomes:

```yaml
      - run: python3 scripts/ci.py provision --target macos
      - run: python3 scripts/ci.py build --target macos
      - run: python3 scripts/ci.py assert-capabilities --target macos
```

`release.yml` — three jobs collapse into one matrix (OQ-4 ruling), `fail-fast: false`:

```yaml
    strategy:
      fail-fast: false
      matrix:
        include:
          - {os: macos-14,       target: macos,   archive: 'Halcyon-macos-arm64-'}
          - {os: windows-latest, target: windows, archive: 'Halcyon-windows-x64-'}
          - {os: ubuntu-latest,  target: linux,   archive: 'Halcyon-linux-x64-'}
```

with a uniform body:

```yaml
      - run: python3 scripts/ci.py provision --target ${{ matrix.target }}
      - run: python3 scripts/ci.py build --target ${{ matrix.target }}
      - run: python3 scripts/ci.py assert-capabilities --target ${{ matrix.target }}
      - run: python3 scripts/ci.py package --target ${{ matrix.target }} --version ${{ env.HALCYON_VERSION }}
      - run: python3 scripts/ci.py release-preflight --version ${{ env.HALCYON_VERSION }} --target ${{ matrix.target }}
      - uses: softprops/action-gh-release@v2
        if: startsWith(github.ref, 'refs/tags/v')
        with:
          files: Halcyon/${{ matrix.archive }}${{ env.HALCYON_VERSION }}.*
          fail_on_unmatched_files: true
```

**Exercising `release.yml` without cutting a tag** (contract: 「release tag 實發」is out of scope):
add a `workflow_dispatch` trigger with a `version` string input defaulting to
`v0.0.0-dryrun`. `HALCYON_VERSION` resolves to `github.ref_name` on a tag push and to the
dispatch input otherwise. The publish step is gated on `startsWith(github.ref, 'refs/tags/v')`,
so a `workflow_dispatch` run executes provision → build → assert → package →
**release-preflight** (which is the actual verification: the archive exists at the exact path
`action-gh-release` would glob) and stops before publishing. This gives AC4 coverage of every
release step except the credentialed upload, with no tag pushed and no release created.
`workflow_dispatch` can be run from the working branch, which also closes the "Windows/Linux
builds are only exercised on a tag" blind spot for this round without changing PR CI scope (PL-5
stays parked).

**Carried over verbatim** (G-9): `ci.yml:1-4` and `release.yml:1-19`'s comment blocks —
including the "don't 'simplify' this back" sibling-checkout note, the `build_apps.py`
single-entry-point note with its artifact path table, and the whole
`continue-on-error: true` removal paragraph. To that last block, append one sentence: that
`fail-fast: false` is **not** `continue-on-error` — it lets sibling jobs finish, it does not let
a job pass while failing — so a future reader does not "clean up" one into the other.

R-8 caching: `cache: true` on `subosito/flutter-action` in every job. **Ordering constraint
(Spec §6): this line is added only after WP-C's assertions are landed and demonstrated red.**
R-8 must never be traded against R-7. The pub-cache `actions/cache` block is deferred to WP-F
step F6 for the same reason.

**Constraints:** AC3 — after the rewrite, **every `run:` block in both files is exactly one line
beginning `python3 scripts/ci.py`**; anything else must be a `uses:` step. R-5 — no `shell: bash`
anywhere in either file. No `ref:` added to the ceyx checkout (OQ-3). No `flutter-version` change (G-6).

**Acceptance criteria:**
- [ ] `grep -n "shell: bash" .github/workflows/*.yml` returns no lines.
- [ ] `grep -n "run:" .github/workflows/*.yml | grep -v "python3 scripts/ci.py"` returns no lines
      (this is AC3 stated mechanically).
- [ ] `grep -n "run: |" .github/workflows/*.yml` returns no lines (no multi-line run blocks remain).
- [ ] `grep -c "fail-fast: false" .github/workflows/ci.yml` ≥ 1 and same for `release.yml`.
- [ ] `grep -n "don't \"simplify\" this back" .github/workflows/ci.yml` and
      `grep -n "continue-on-error" .github/workflows/release.yml` both return the carried-over
      comment lines.
- [ ] `grep -n "ref:" .github/workflows/*.yml` returns no lines (OQ-3 honoured).
- [ ] `python3 -c "import yaml,sys;[yaml.safe_load(open(p)) for p in sys.argv[1:]]" .github/workflows/ci.yml .github/workflows/release.yml`
      exits 0 (YAML is parseable). If PyYAML is absent, use `gh workflow view` after push instead
      and record which instrument was used.

**Steps:**

- [ ] **D1: Rewrite `ci.yml`** — matrix + one-line runs; carry the header comment verbatim.
      Verify: all four grep acceptance commands.
- [ ] **D2: Rewrite `release.yml`** — one matrix, `workflow_dispatch` + `HALCYON_VERSION`,
      tag-gated publish. Verify: the same greps plus `grep -n "workflow_dispatch" release.yml`.
- [ ] **D3: Do NOT add `cache: true` yet.** Leave a single-line comment `# R-8 cache added in F6
      after R-7 assertions are green (Spec §6)` where it will go. Verify:
      `grep -n "cache: true" .github/workflows/` returns no lines at this step.
- [ ] **D4: Commit** `git commit -- .github/workflows/ci.yml .github/workflows/release.yml -m "refactor(ci): collapse workflows to matrix jobs calling scripts/ci.py"`

---

### WP-E — Tests: golden argv, Windows path lints, policy greps

**Files (owned exclusively):**
- Create: `scripts/ci/tests/__init__.py`
- Create: `scripts/ci/tests/test_render.py`
- Create: `scripts/ci/tests/test_policy.py`
- Create: `scripts/ci/tests/golden/{macos,windows,linux,android-apk,web}.txt`

**Interfaces:** Consumes `phases.print_plan` / the shared argv renderer, and `targets.spec`.
Produces nothing other packages import.

**Behavior:**

`test_render.py` — the Spec §4.8 defence. Because platform is a *parameter* and argv rendering is
a *pure function*, the Windows argv can be asserted from a macOS laptop with no Windows host.
- One golden-file test per target: rendered argv equals `golden/<target>.txt` exactly. Any flag
  regression (a dropped `--fetch-native`, a changed archive name) is caught pre-commit on any host.
- Two zero-cost lints over the **rendered Windows argv**: every path-typed element matches
  `^[A-Za-z]:[\\/]`, and no element begins with `/`. These catch the drive-letter-eaten family
  (`D:/a/... → \d\a\...`) statically.
- **What this does not prove, stated in the test module docstring:** nothing here establishes
  Windows *runtime* behaviour. It eliminates the flag/path families locally; the rest still needs
  a real runner.

`test_policy.py` — the mechanical restatement of AC3/R-5/G-1/G-5, run as tests so a *future* edit
is caught, not just today's state (the 2026-08-30 lesson: a comment stating a rule does not stop
new code violating it; only a mechanical check does, and the check must cover future additions):
- `test_no_shell_true`: no `shell=True` in any `scripts/ci/**.py` or `scripts/ci.py`.
- `test_no_target_branching`: no `if target ==` / `if platform ==` outside `targets.py`.
- `test_no_pipe_grep`: no argv list literal in `scripts/ci/` contains `"|"` or `"grep"`.
- `test_workflows_single_line_runs`: parse both YAML files as text; every `run:` value is a single
  line beginning `python3 scripts/ci.py`.
- `test_no_bash_shell_in_workflows`: no `shell: bash` in either file.
- `test_pin_file_untouched`: `scripts/ceyx_release_pin.json`'s SHA-256 equals the value frozen in
  the test at branch start (G-6, mechanical).

**Constraints:** `unittest` only (stdlib, G-11). Tests must pass on macOS, Windows and Linux — no
test may shell out to a platform-specific tool.

**Acceptance criteria:**
- [ ] `python3 -m unittest discover -s scripts/ci/tests -v` exits 0 with ≥ 11 tests run.
- [ ] Deleting `--fetch-native` from `targets.py` makes `test_render` fail naming `windows`
      (demonstrate once — a test never seen red is not evidence).
- [ ] Adding `shell: bash` to a scratch copy of `ci.yml` makes `test_no_bash_shell_in_workflows`
      fail (demonstrate once).
- [ ] `golden/windows.txt` contains the literal `--fetch-native`.

**Steps:**

- [ ] **E1: Write `test_render.py` against the frozen renderer signature; run it and confirm it
      FAILS** with `NotImplementedError` while WP-B is still stubbed. Expected output contains
      `NotImplementedError`. This is the red half of the red→green evidence.
- [ ] **E2: Generate the five golden files** from WP-B's renderer once it lands, then **hand-verify
      each against the current workflow files** (`ci.yml:125`, `release.yml:60/102/138`) —
      generating a golden from the implementation and then asserting the implementation against it
      proves nothing on its own. Record the line-by-line correspondence in the commit message.
- [ ] **E3: Write `test_policy.py`.** Verify: the two demonstrate-once red states above.
- [ ] **E4: Run the full suite green.** `python3 -m unittest discover -s scripts/ci/tests -v; echo RC=$?`
      Expected: `OK` and `RC=0`.
- [ ] **E5: Commit** `git commit -- scripts/ci/tests/ -m "test(ci): golden argv rendering and mechanical policy checks"`

---

### WP-F — Integration, local gate, push, CI loop (serial, last)

**Files:** none owned exclusively; this package runs commands and, if a fix is needed, routes it
back to the owning package's member. **WP-F does not edit other packages' files.**

**Behavior:** the local gate that must be green before the first push, then the push and the CI
loop. Per the contract's CI-loop clause, the main conversation does not debug or write fixes here:
it confirms *status* and dispatches.

**Steps:**

- [ ] **F1: `flutter analyze` with self-captured RC** (AC6). Never trust a harness notification —
      capture inside the artifact (2026-08-23):

```bash
mkdir -p docs/logs/2026-08-31
{ flutter analyze; RC=$?; echo "RC=$RC"; } > docs/logs/2026-08-31/local-analyze.txt 2>&1
tail -n 3 docs/logs/2026-08-31/local-analyze.txt
```

Expected: `No issues found!` and a last line exactly `RC=0`.

- [ ] **F2: `flutter test -j 1` with self-captured RC** (AC6). `-j 1` is mandatory: parallel
      output overwrites and loses filenames (2026-08-17).

```bash
{ flutter test -j 1; RC=$?; echo "RC=$RC"; } > docs/logs/2026-08-31/local-test.txt 2>&1
tail -n 3 docs/logs/2026-08-31/local-test.txt
grep -c "All tests passed" docs/logs/2026-08-31/local-test.txt
```

Expected: last line exactly `RC=0`, and the declared test count equals the executed count.

- [ ] **F3: Python suite + every `--print-plan` target:**

```bash
{ python3 -m unittest discover -s scripts/ci/tests -v; RC=$?; echo "RC=$RC"; } \
  > docs/logs/2026-08-31/local-pytests.txt 2>&1
for t in macos windows linux android-apk web; do
  { python3 scripts/ci.py --print-plan --target "$t"; RC=$?; echo "RC=$RC"; } \
    > "docs/logs/2026-08-31/plan-$t.txt" 2>&1
done
```

Expected: `RC=0` in all six files; `plan-windows.txt` contains `--fetch-native`.

- [ ] **F4: Full local dry run of the macOS release path** (the only platform buildable here):

```bash
python3 scripts/ci.py provision --target macos
python3 scripts/ci.py build --target macos
python3 scripts/ci.py assert-capabilities --target macos
python3 scripts/ci.py package --target macos --version v0.0.0-local
python3 scripts/ci.py release-preflight --version v0.0.0-local --target macos
```

Expected: each exits 0; `build/ci-logs/macos-*.txt` each end in `RC=0`;
`Halcyon-macos-arm64-v0.0.0-local.zip` exists. Delete the zip afterwards (it must not be committed).

- [ ] **F5: Push the branch and open the PR.** Branch `ci/python-rewrite`, PR into `main` so
      `ci.yml` fires on `pull_request`. Then trigger `release.yml` manually against the branch:
      `gh workflow run Release --ref ci/python-rewrite -f version=v0.0.0-dryrun`.
      Status is read with an explicit empty-string comparison (G-10):

```bash
gh run list --branch ci/python-rewrite --limit 20 \
  --json name,status,conclusion,databaseId \
  --jq '.[] | select(.conclusion != "success") | "\(.name) status=\(.status) conclusion=[\(.conclusion)]"'
```

An empty `conclusion` means **in progress**, not failed — `//` fallback in jq does not fire on
`""` (2026-08-28). Never treat `[]` in the bracket as a failure.

- [ ] **F6: Only after every job is green, add R-8 caching** (Spec §6 ordering constraint):
      `cache: true` on `subosito/flutter-action` in both workflows, plus an `actions/cache` for
      the pub cache keyed on `${{ runner.os }}-pub-${{ hashFiles('Halcyon/pubspec.lock') }}`.
      Any cache of fetched ceyx libraries keys on `(platform, ceyx tag, asset sha256)` so a pin
      change can never be served a stale artefact. Re-run CI; green again before merge.
- [ ] **F7: Merge to `main`, then verify on `main` independently** (AC5 — in-branch green does not
      transfer, 08-16 family):

```bash
gh run list --branch main --limit 10 --json name,status,conclusion \
  --jq '.[] | select(.conclusion != "success") | "\(.name) [\(.conclusion)]"'
```

Expected: empty output once all `main` runs have completed.

---

## 4. Branch and PR strategy

- **One branch: `ci/python-rewrite`**, cut from `main`. All five packages commit to it.
- **Shared-tree discipline** (2026-08-24 / 2026-08-25 lessons, mandatory for every member):
  - Never `git add -A`. Always `git add <your own paths>`.
  - **Always commit with a pathspec:** `git commit -- <your own paths> -m "…"`. A bare
    `git commit` sweeps the whole index and will take a teammate's staged work.
  - If a file is moved with `git mv`, list **both** old and new paths in the pathspec, then
    confirm `git status --porcelain` shows zero residue.
  - Never `git stash`, `git reset`, `git checkout --`, or `git clean` on the shared tree.
  - Before each commit: `git rev-parse --abbrev-ref HEAD` must print `ci/python-rewrite`.
    `git status --porcelain` shows files, not which branch you are on.
- **PR into `main`** so `ci.yml`'s `pull_request` trigger fires. Do not push directly to `main`.
- **Exercising `release.yml` without a tag:** `workflow_dispatch` with a `version` input (WP-D).
  Every release step except the credentialed `action-gh-release` upload runs; `release-preflight`
  asserts the archive exists at the exact path that action would glob. No tag is pushed and no
  GitHub Release is created, satisfying the contract's out-of-scope clause.
  *Rejected alternative:* pushing a throwaway `v0.0.0-test` tag — it creates a real Release, is
  hard to fully undo, and is exactly what the contract excludes.
- **Merge:** squash or merge commit, then AC5's independent `main` verification (F7). In-branch
  green is not transferable evidence.

---

## 5. Risk register

| id | Risk | Why it is likely | Observable signal | Owner / response |
|---|---|---|---|---|
| RK-1 | Sibling ceyx checkout not found; `pub get` fails opaquely | Spec §5.1 names this the most likely first-round failure | CI log contains `sibling ceyx checkout not found at <path>` — the named error WP-A adds; without it the signal is an unreadable pub resolution error | WP-A's guard converts an opaque failure into a diagnosis. If it fires, the fault is the workflow's `path:` values, not `ci.py` |
| RK-2 | `python3` is not on PATH on `windows-latest` (it is often `python`) | GitHub's Windows images expose `python`; `python3` may be an App Execution Alias stub that exits 9009 | Windows job fails immediately with `Python was not found` or exit `9009`, before any `ci.py` output | WP-D: on the Windows matrix leg the runner-provided `python` may be required. Verify on the first push; if it fires, `targets.py` gains a `python_exe` data field — **not** an `if os == windows` in the workflow |
| RK-3 | `ci.py` runs from the wrong cwd because `defaults: working-directory: Halcyon` interacts with matrix jobs | Every step is relative to `Halcyon/` today | `FileNotFoundError: scripts/build_apps.py` | WP-A's repo-root-from-`__file__` resolution makes cwd irrelevant. If it still fires, the `defaults:` block was dropped in the rewrite — grep for it |
| RK-4 | `pod install` on the macOS matrix leg is slow or fails on a cold CocoaPods cache | It runs today in a dedicated job only (`ci.yml:121`); now it is part of `provision` | macOS job time jumps, or `pod install` non-zero in `build/ci-logs/macos-provision.txt` | `provision` is data-driven; the step is unchanged from today's invocation. If it fails, it is an environment issue, not a rewrite defect — check the log's `RC=` trailer, not the harness notification |
| RK-5 | `package()`'s zip layout differs from `ditto`/`Compress-Archive` and users get a nested or flattened archive | Three tools with three different default layouts are being unified into one | `unzip -l` listing lacks the `Halcyon.app/` prefix (macOS) or has a `Release/` prefix (Windows) | WP-B acceptance criterion asserts the listing prefix explicitly. This is the highest-value single check in WP-B |
| RK-6 | Windows `assert-capabilities` fails because `H-SIZED-SYMBOL-NM` was accidentally left `valid_on` Windows | The exclusion is a data field, easy to over-copy | Windows job fails naming `H-SIZED-SYMBOL-NM` | WP-C acceptance criterion asserts the tuple does not contain `windows` |
| RK-7 | A skipped assertion produces a green report indistinguishable from a full run | 2026-08-25 lesson, observed in this repo | Absence of `SKIP:` lines when a skip occurred, or a summary whose skipped count is 0 while a tool is missing | WP-C: skip on the native platform is a hard failure; every skip prints one line; the count is in the summary |
| RK-8 | ceyx's unpinned default branch changes mid-migration and a ceyx breakage is misread as a rewrite defect | OQ-3 leaves it unpinned; Spec §5.1 flags exactly this ambiguity | A CI failure that reproduces on `main`'s unchanged workflow too, or a failure inside ceyx's own build output | Before diagnosing any red as a rewrite defect, re-run the **pre-rewrite** command once on the same runner. If both fail, it is ceyx. Escalate to the user rather than "fixing" it |
| RK-9 | `workflow_dispatch` on `release.yml` still publishes because the `if:` guard is wrong | The guard is one expression away from publishing a real Release | A GitHub Release appears | WP-D acceptance: `grep -n "startsWith(github.ref, 'refs/tags/v')"` must return the publish step's guard. Check before the first dispatch, not after |
| RK-10 | R-8 caching lands early and serves a stale artefact past a green assertion | Ordering constraint exists precisely because this is tempting | `cache: true` present while WP-C's red-state artifacts are absent | WP-D step D3 forbids it; F6 is the only place it may be added |
| RK-11 | A member's bare `git commit` sweeps another member's staged work | Happened in this repo on 2026-08-24 | Commit message does not match the commit's file list | §4's pathspec rule; check `git show --stat HEAD` after every commit |

---

## 6. Known gaps and parking lot

**Known gap (OQ-2 ruling, recorded not silently dropped):** there is **no assertion that the
packaged app actually launches.** `H-BUNDLE-RUNS` would catch the class of failure where every
symbol is present and the bundle is still unusable (missing runtime DLL, bad rpath). A Flutter GUI
app has no headless entry point today, so it needs either a `--smoke-test` flag in the app (an app
behaviour change — out of scope, G-6) or a windowing-capable runner. Deferred as `PL-7`. This
means "builds green, ships broken" remains possible for the launch-path family after this round.

Parking lot carried from Spec §7, plus this round's additions:

| id | Item |
|---|---|
| PL-1 | `package_windows.sh` → Python. Not CI, not urgent |
| PL-2 | R-2's unmet clauses (committed binaries in ceyx; macOS excluded from the pin) — ceyx-side |
| PL-3 | `build_apps.py:631` and `:674` `shell=True` (cmd.exe, not MSYS) |
| PL-4 | Containerised Linux CI, if a Linux-only environment-dependent failure ever appears |
| PL-5 | Windows/Linux **build** jobs in PR CI, not only on release tags |
| PL-6 | `ceyx_release_pin.json` provenance comment says v0.1.4 while tag and URL say v0.1.5 |
| PL-7 | `H-BUNDLE-RUNS` — packaged-app launch smoke assertion (OQ-2 deferral) |
| PL-8 | Pin the `jhangyu/ceyx` checkout to a `ref:` (OQ-3 deferral). Raise immediately after this migration |
| PL-9 | Demonstrate `H-SIZED-SYMBOL-NM`'s red state on a real Windows runner, then decide whether to re-include Windows in its `valid_on` |

---

## 7. Non-goals (restated verbatim from Spec §7)

1. **ceyx's own build rewrite** — separate contract.
2. **Any third-party pin change** — 載體中立. Includes `ceyx_release_pin.json` values,
   `flutter-version: '3.44.6'`, `pubspec.lock`, and every `build_apps.py` flag default.
3. **App source behaviour changes** — only CI/build-script changes are permitted.
4. **Actually cutting a release tag** — `release.yml` is validated via `ci.py release-preflight`
   under `workflow_dispatch`, without publishing.
5. **Rewriting `build_apps.py`** — it is called, not replaced.
6. **Converting `package_windows.sh`** — a macOS-hosted developer hand-off tool, outside the CI path.
7. **Adopting vcpkg/Conan** — R-1 does not apply.
8. **Containerising Linux/Android** — R-6 does not apply in its strong form.
9. **Fixing the two `build_apps.py` `shell=True` sites** — PL-3.
10. **Adding Windows/Linux build coverage to PR CI** — PL-5.

Plus this plan's own additions: **`H-BUNDLE-RUNS` is not implemented** (OQ-2), and **the ceyx
checkout is not pinned** (OQ-3).

---

## 8. Self-review

**1. Spec coverage.** Every Spec section maps to a package: §2.1/§2.2 fate table → WP-A
(`targets.py` transcription) + WP-D (workflow rewrite); §4.1 command surface → WP-A (CLI) + WP-B
(implementations); §4.2 module layout → the §1 file table; §4.3 YAML/Python split → WP-D
acceptance greps; §4.4 matrix + fail-fast → WP-D; §4.5 R-7 assertions and skip semantics → WP-C;
§4.6 exit codes/logging → G-1..G-4 + WP-A `run.py`/`report.py`; §4.7 Windows shell policy → WP-A
(interpreter guard) + WP-D (no `shell: bash`) + WP-E (`test_policy`); §4.8 `--print-plan` → WP-B +
WP-E golden files; §5.1 sibling checkout → G-9 + WP-A named error; §5.2 pin as data → WP-C
`H-DECODER-DEPS` + WP-E `test_pin_file_untouched`; §5.3 `build_apps.py` delegation → WP-B `build()`
+ G-7; §5.4 macOS arm64-only → `H-ARCH`; §5.5 coverage gap → PL-5, partially mitigated by WP-D's
`workflow_dispatch`; §6 ordering → WP-D step D3 + WP-F step F6; §7 non-goals → §7 here.
No gap found.

**2. Placeholder scan.** No "TBD", "TODO", "similar to Task N", or uncheckable criteria. Every
acceptance criterion is a command with an expected output. The one genuinely unknown —
RK-2's `python3` vs `python` on `windows-latest` — is written as a risk with a named signal and a
pre-decided response, not as a placeholder.

**3. Type consistency.** `RunResult`, `Assertion`, `TARGETS`/`spec()`, `log_path_for`/`write_log`/
`summary`/`skip_line`, and the six `phases.*` signatures are declared once in §2 and referenced by
those exact names in WP-A/B/C/E. Assertion ids (`H-ARCH`, `H-DECODER-PRESENT`, `H-DECODER-DEPS`,
`H-DECODER-HASH`, `H-SIZED-SYMBOL`, `H-SIZED-SYMBOL-NM`) are identical in the WP-C table, its
acceptance criteria, RK-6 and PL-9. `targets.py` key names in WP-A's behaviour section match those
consumed by WP-B's `package()` and WP-C's `run_suite()`.
