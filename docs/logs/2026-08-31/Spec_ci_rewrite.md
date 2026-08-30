# Spec: Halcyon unified cross-platform Python CI scripts

> Status: requirements confirmation + specification. Written 2026-08-31 against the frozen
> contract `docs/logs/2026-08-31/Contract_ci_rewrite.md`.
> Normative inputs: that contract, plus ceyx `docs/logs/2026-08-30/Requirements_ci_rewrite.md`
> (R-1..R-8, frozen user requirements for the *sibling* repo).
> Evidence markers used throughout: **[V]** verified in this repo at the cited file:line;
> **[H]** hypothesis with stated basis; **[I]** inferred, not verified.

---

## 0. Verbatim contract quote (AC1 prerequisite)

The following is reproduced **verbatim** from `docs/logs/2026-08-31/Contract_ci_rewrite.md:3-24`.
It is not paraphrased and must not be paraphrased in later rounds.

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

---

## 1. Executive summary — the five things that decide this design

1. **Halcyon is not ceyx.** ceyx's rewrite is about *acquiring and compiling six third-party
   native libraries*. Halcyon compiles no third-party library in CI: it consumes ceyx's
   prebuilt, hash-pinned release assets (`scripts/ceyx_release_pin.json`) **[V]**. Therefore
   R-1, R-1a/b/c, R-2, R-3 and R-6 land differently here — several as "already satisfied by a
   different mechanism" rather than "does not apply". §3 states a verdict for every one.
2. **The single build entry point already exists and is already Python.** `scripts/build_apps.py`
   is 2,249 lines of stdlib-only Python that performs host checks → Halide dist → native build →
   `flutter pub get` + `flutter build` → artifact verification (`build_apps.py:1-19`) **[V]**.
   The rewrite is therefore *not* "write a build script"; it is "hoist the remaining CI logic
   (analyze, test, package, publish-preflight, artifact assertions) out of YAML into a sibling
   Python entry point, and reduce the workflows to environment setup plus one call per job."
3. **The residual shell is in packaging and gating, not building.** `release.yml:63-66` uses a
   bash `ditto` heredoc; `release.yml:141-144` uses a bash `find`/`tar` pipeline; `release.yml:105`
   uses PowerShell `Compress-Archive`. These are three implementations of one operation
   ("package the built artifact for this platform") and are the largest single source of
   platform drift left in the repo **[V]**.
4. **`ci.yml` has no matrix at all** — it is three near-identical copy-pasted jobs
   (`ci.yml:18-97`) plus a macOS-only build job (`ci.yml:99-125`) **[V]**. R-4's
   `fail-fast: false` has literally nothing to attach to today. Introducing a matrix is a
   prerequisite for satisfying R-4, and is also the cheapest way to delete ~60 lines of
   duplication.
5. **There is no caching of any kind.** No `actions/cache`, no `cache: true` on
   `subosito/flutter-action`, no pub-cache restore, in either workflow **[V]**. R-8 is a pure
   addition here, not a migration.

---

## 2. Current-state inventory and fate

### 2.1 Workflow steps

`.github/workflows/ci.yml` — 4 jobs, 22 steps.

| # | Job | Step (file:line) | What it is | Fate |
|---|---|---|---|---|
| 1 | all 4 | `checkout@v4 path: Halcyon` (`ci.yml:22`, `49`, `76`, `103`) | environment | **Kept in YAML** (AC3 explicitly exempts checkout) |
| 2 | all 4 | `checkout@v4 jhangyu/ceyx path: ceyx` (`ci.yml:26`, `53`, `80`, `109`) | environment — the sibling-repo constraint | **Kept in YAML.** Load-bearing; see §5.1 |
| 3 | all 4 | `subosito/flutter-action@v2` pinned `3.44.6` (`ci.yml:31`, `58`, `85`, `112`) | environment | **Kept in YAML**, gains `cache: true` (R-8) |
| 4 | all 4 | `flutter pub get` (`ci.yml:37`, `64`, `91`, `118`) | build logic | **Absorbed** → `ci.py verify` / `ci.py build` |
| 5 | 3 | `flutter analyze` (`ci.yml:40`, `67`, `94`) | build logic | **Absorbed** → `ci.py verify` |
| 6 | 3 | `flutter test -j 1` (`ci.yml:43`, `70`, `97`) | build logic | **Absorbed** → `ci.py verify` |
| 7 | build | `pod install` in `Halcyon/macos` (`ci.yml:121`) | build logic | **Absorbed** → `ci.py build --target macos` (macOS-only phase) |
| 8 | build | `python3 scripts/build_apps.py` (`ci.yml:125`) | build logic | **Delegated**, unchanged: `ci.py build` calls `build_apps.py` and does not reimplement it |
| — | jobs 1-3 | the entire triplication (`ci.yml:18-97`) | structure | **Collapsed to one `matrix` job with `fail-fast: false`** (R-4) |

`.github/workflows/release.yml` — 3 jobs, 20 steps.

| # | Job | Step (file:line) | What it is | Fate |
|---|---|---|---|---|
| 9 | all 3 | dual checkout + flutter-action (`release.yml:38-51`, `78-90`, `117-129`) | environment | **Kept in YAML** |
| 10 | linux | `apt-get install ninja-build libgtk-3-dev` (`release.yml:132`) | environment provisioning | **Absorbed** → `ci.py provision --target linux` (it is a *host prerequisite*, and `build_apps.py` already owns host/tool checks, `build_apps.py:11`) |
| 11 | all 3 | `flutter pub get` (`release.yml:53`, `92`, `134`) | build logic | **Absorbed** |
| 12 | macos | `pod install` (`release.yml:56`) | build logic | **Absorbed** |
| 13 | all 3 | `python3 scripts/build_apps.py <target> [--fetch-native]` (`release.yml:60`, `102`, `138`) | build logic | **Delegated**, flags preserved byte-for-byte — including Windows `--fetch-native`, whose rationale is recorded at `release.yml:96-101` and is a correctness requirement, not a preference **[V]** |
| 14 | macos | bash `ditto -c -k --keepParent` (`release.yml:63-66`) | packaging | **Absorbed** → `ci.py package --target macos` |
| 15 | windows | pwsh `Compress-Archive` (`release.yml:105`) | packaging | **Absorbed** → `ci.py package --target windows` |
| 16 | linux | bash `find`+`tar` (`release.yml:141-144`) | packaging | **Absorbed** → `ci.py package --target linux` |
| 17 | all 3 | `softprops/action-gh-release@v2` (`release.yml:69`, `108`, `146`) | publishing | **Kept in YAML.** Uploading to the GitHub Releases API is an environment/credential action, and re-implementing it in Python would need `GITHUB_TOKEN` handling for zero gain. `fail_on_unmatched_files: true` is retained |

### 2.2 Scripts under `scripts/`

| Path | Lines | What it is | Fate |
|---|---|---|---|
| `build_apps.py` | 2,249 | Single build entry point; native + Flutter, six targets | **Kept, unchanged in behaviour.** `ci.py` *calls* it. Explicitly NOT merged into `ci.py`: it has a documented capability map against two deleted predecessors (`build_apps.py:22-140`) and rewriting it would break 載體中立 |
| `ceyx_release_pin.json` | 70 | Pinned ceyx release tag + per-asset SHA-256 | **Kept, byte-identical.** Touching it violates the contract's 載體中立 clause. See §5.2 and OQ-3 |
| `check_dng_ffi_artifacts.py` | 163 | FFI artifact presence + `dng_decode_and_process_sized` symbol check; currently *manually run*, self-describes as "not an automated build gate" (`check_dng_ffi_artifacts.py:27`) **[V]** | **Kept as a module, promoted to a CI gate** via `ci.py assert-capabilities`. Its `skipped` semantics must be tightened first — see §4.5 and OQ-1 |
| `dng_ffi_artifacts.json` | 38 | Data manifest for the above | **Kept, extended** with the R-7 fields (`measures`/`valid_on`/`why_valid`/`red_state`), see §4.5 |
| `package_windows.sh` | 198 | Bash: builds a two-repo source hand-off zip for a Windows laptop via `git archive` | **Kept for now, out of the CI path.** It is a *developer hand-off* tool, never invoked by any workflow **[V]** (grep of both YAML files finds no reference). It is bash-on-macOS, so R-5 does not reach it. Converting it is a parking-lot item, not in-scope — see PL-1 |
| `gen_windows_associations.dart` | 64 | Generates Windows file associations; invoked *by* `build_apps.py:1957` **[V]** | **Kept, untouched.** Already behind the single entry point |
| `focus_forensics.sh` | 46 | Local macOS focus-debugging aid; zero references outside itself **[V]** | **Kept, untouched.** Not CI, not build |
| `scripts/windows/README_WINDOWS.md` | — | Hand-off pack README consumed by `package_windows.sh:105` | **Kept** |
| `scripts/tmp/` | — | Scratch (already pruned from hand-off packs, `package_windows.sh:41`) | **Untouched** |
| **`scripts/ci.py`** | new | The unified CI entry point specified in §4 | **Created** |
| **`scripts/ci/`** | new | Its supporting modules (see §4.2) | **Created** |

**Net:** zero deletions. The rewrite is subtractive in *YAML*, additive in `scripts/`. That is
deliberate — every deletion is an opportunity to silently drop a behaviour, and the contract's
"behaviour-preserving migration" clause makes that the dominant risk.

---

## 3. R-1..R-8 applicability matrix for Halcyon

Verdict vocabulary: **APPLIES** (adopt as written) / **PARTIALLY APPLIES** (adopt the principle,
with a stated Halcyon-specific reading) / **DOES NOT APPLY** (with reason).
Per AC1, silence is not permitted; every row carries a verdict *and* a reason.

| Req | Verdict | Reason |
|---|---|---|
| **R-1** — consume all third-party libs from a package manager (vcpkg/Conan) rather than self-building | **DOES NOT APPLY** | R-1 governs the acquisition of ceyx's six native codec libraries. Halcyon builds none of them. Its only binary third-party dependency is *ceyx itself*, and Halcyon already consumes it as a **pinned, hash-verified prebuilt release asset** (`scripts/ceyx_release_pin.json:39-68`) **[V]** — which is functionally the pattern R-1 is reaching for (an upstream-published artefact, not a locally compiled one), obtained from ceyx's own release channel rather than a third-party registry. Halcyon's *Dart* dependencies are already managed by pub with a committed `pubspec.lock`. Adopting vcpkg/Conan in Halcyon would add a tool dependency with nothing to manage. **Consequence for the plan: nothing.** |
| **R-1a** — the registry/self-built split is declared as data, per component, with a reason | **PARTIALLY APPLIES** | The split concept survives in degenerate form and is already data: `ceyx_release_pin.json` declares *per platform* which libraries are fetched, and its `_comment` records why macOS is deliberately absent (six interdependent dylibs with install-name/codesign wiring the release assets cannot satisfy) and why Windows needs three assets not one (LGPL-3 requires libheif/libde265 stay separate shared libraries) (`ceyx_release_pin.json:12-17`, `34-37`) **[V]**. That is exactly R-1a's "recorded reason" discipline, already met. **Requirement on this rewrite: do not regress it** — `ci.py` must read this file rather than encode any platform's library list in code. |
| **R-1b** — package manager and Python rewrite are both mandatory; neither substitutes for the other | **PARTIALLY APPLIES** | The package-manager half is void here (R-1). The **Python half applies in full and is the entire point of this contract**. R-1b's check clause — "the self-built path contains no Unix-like shell step on any platform" — transfers directly and is folded into R-5 below. |
| **R-1c** — a component moving self-built → registry must be a one-line manifest edit | **PARTIALLY APPLIES** | Read for Halcyon as: *macOS moving from committed dylibs to the pinned-release fetch must be a one-line edit to `ceyx_release_pin.json`, not a code change.* The file is already shaped for this (per-platform `libraries` lists, "Linux uses a one-element list so there is exactly one code path", `ceyx_release_pin.json:17`) **[V]**. `ci.py` must not introduce any `if platform == "macos"` branch that would break that property. Actually performing the macOS move is out of scope (載體中立). |
| **R-2** — two pipelines: dependency build manual+published by hash; app pipeline only downloads+verifies+builds; binaries stop being committed | **PARTIALLY APPLIES — and Halcyon is the "app pipeline"** | The two-pipeline split already exists across the repo boundary: ceyx's release workflow is the dependency pipeline; Halcyon's CI is the application pipeline, and it already "downloads the pinned artefact, verifies its hash, and builds" (`ceyx_release_pin.json:3-8`) **[V]**. Two clauses do **not** yet hold: (a) *binaries are still committed* — ceyx carries a committed `dng_decoder_native.dll` that `release.yml:96-101` documents as unvalidated and works around with `--fetch-native` **[V]**; (b) macOS is excluded from the pin entirely. Both are **ceyx-side and out of scope** per the contract. **Requirement on this rewrite:** preserve `--fetch-native` on the Windows job exactly, and make the hash-mismatch failure visible in `ci.py`'s log output. **PL-2** records the residual. |
| **R-3** — every platform configuration is a named `CMakePresets.json` preset; no configure arg exists only in a workflow | **PARTIALLY APPLIES** | Halcyon runs no CMake configure of its own in CI; the presets live in ceyx and `build_apps.py` already asserts the required preset exists for the target (`build_apps.py:87-89` capability map, ref `bw:380`) **[V]**. The *principle* — "no argument exists only inside a workflow file" — applies with full force and is the sharpest available statement of this rewrite's goal. Today the violations are: `--fetch-native` (Windows only, `release.yml:102`), `-j 1` (test jobs only), the three divergent packaging invocations, and the Linux apt package list **[V]**. **After the rewrite, every one of these must be data inside `scripts/ci/`, invocable locally by the same name CI uses.** This is R-3 restated as: `python3 scripts/ci.py build --target windows` must be the *whole* command on both a runner and a laptop. |
| **R-4** — `fail-fast: false` on every matrix; keep-going builds | **APPLIES** (contract-flagged) | Adopt in full, with one honest caveat. `fail-fast: false` applies once `ci.yml`'s three duplicated jobs become a matrix (§4.4) — today there is no matrix to set it on **[V]**, and separate jobs already don't cancel each other, so this is a *precondition-creating* change, not a behaviour fix. The keep-going half has **no direct Halcyon analogue**: `flutter analyze` already reports all issues, and `flutter test` already runs all tests. The transferable form is at the *step* level: within one job, an analyze failure must not prevent the test run, and a test failure must not prevent artifact/capability assertions. `ci.py verify` therefore runs every phase, accumulates failures, and exits non-zero once at the end — see §4.6. |
| **R-5** — no Unix-like shell for any Windows build step; argument lists, never a shell that reinterprets argv | **APPLIES IN FULL** (contract-flagged) | The mechanism R-5 guards against — MSYS/Git-Bash rewriting argv and eating drive letters — is live on any `shell: bash` step on a `windows-latest` runner. **Current state is accidentally compliant and must be made structurally compliant:** neither Windows job declares `shell: bash` today, so both inherit `pwsh` **[V]**, but nothing prevents the next edit from adding one. Post-rewrite the rule becomes a mechanical grep (§4.7). **One declared deviation, reported not adapted:** `build_apps.py` uses `subprocess.run(..., shell=True)` at two sites — `build_apps.py:631` (`vcvars64.bat && set`, with a rationale comment at `:627-630`) and the `.bat`/`.cmd` path near `build_apps.py:674` **[V]**. This is *cmd.exe*, not MSYS bash, so it is not R-5's path-mangling family; and `build_apps.py:132` records that arguments carrying cmd metacharacters are already refused loudly (audit item S6). Per 載體中立 these two sites are **not changed** by this rewrite. They are recorded here rather than silently left unmentioned, and enter the parking lot as **PL-3**. The new `scripts/ci.py` code is held to the strict rule: zero `shell=True`, ever. |
| **R-6** — Linux/Android environments pinned as container images; same image locally and in CI; `act` usable | **DOES NOT APPLY** | R-6's payload is reproducing a *native toolchain* (compilers, sysroots, NDK) whose drift silently changes a compiled artefact. Halcyon compiles no native code on Linux — it fetches ceyx's `.so` by pinned SHA-256, and the only Linux host requirement is `ninja-build`+`libgtk-3-dev` for the Flutter shell (`release.yml:132`) **[V]**. The reproducibility that matters is already pinned by stronger instruments: `flutter-version: '3.44.6'` exact **[V]**, a committed `pubspec.lock`, and the asset digests. Containerising to pin two apt packages buys little and costs an image-maintenance burden. **Adopted in weakened form:** `ci.py provision --target linux` centralises the apt list as data, so a future container image has one place to read it from. Revisit if a Linux-only failure ever proves environment-dependent (**PL-4**). |
| **R-7** — every platform's artefact carries capability assertions; the assertion must test the CAPABILITY, not a platform-specific proxy; each needs a demonstrated red state | **APPLIES** (contract-flagged) — **and this is the highest-value item in the rewrite** | Halcyon today has zero automated artefact assertions in CI: `ci.yml` builds macOS and then checks nothing; `release.yml` packages whatever exists and uploads it, with `fail_on_unmatched_files: true` as the only guard **[V]**. Meanwhile `check_dng_ffi_artifacts.py` — a real capability checker for the exact failure mode that would ship a Halcyon build unable to decode RAW — is documented as manual and not a gate (`check_dng_ffi_artifacts.py:27`) **[V]**. Wiring it in is §4.5. R-7's design constraint bites here specifically: its current instrument is `nm`/`dumpbin` **symbol-table presence** for `dng_decode_and_process_sized`, which is precisely the export-table proxy that ceyx found valid on Mach-O/ELF and meaningless on Windows PE (`Spec_build_rewrite.md:855-865`). See §4.5 and **OQ-1**. |
| **R-8** — compiler caching (ccache/sccache) plus CI-level caching; cache keys include target architecture | **PARTIALLY APPLIES** (contract-flagged) | ccache/sccache **does not apply**: Halcyon compiles no C/C++ in CI. CI-level caching **applies and is a pure win**: there is no caching of any kind today **[V]**, and every job re-resolves pub packages and re-downloads the SDK. Adopt `cache: true` on `subosito/flutter-action` and an `actions/cache` for the pub cache keyed on `pubspec.lock` + runner OS. R-8's own note — "it must never be traded against R-7" — is honoured by ordering: R-7 assertions land before R-8 caching (§6). R-8's arch-in-the-key rule transfers to the ceyx-artifact side: any cache of fetched ceyx libraries must key on `(platform, ceyx tag, asset sha256)` so a pin change can never be served a stale artefact. |

**Cross-cutting constraint (載體中立), restated for Halcyon:** this rewrite changes **no**
`ceyx_release_pin.json` value, **no** `flutter-version`, **no** `pubspec.lock` entry, **no**
`build_apps.py` flag, and **no** app source behaviour. Equivalence is judged by *capability*
(§4.5) and by *rendered argv* (§4.8), never by build success or exit code alone.

---

## 4. Target design

### 4.1 Command surface

One entry point, `scripts/ci.py`, subcommand-dispatched. Every subcommand accepts
`--target {macos,windows,linux,android-apk,web}` where meaningful, and every subcommand is
runnable on a developer laptop with the identical string CI uses (R-3's transferred principle).

| Subcommand | Does | Replaces |
|---|---|---|
| `ci.py provision --target T` | Installs/verifies host prerequisites for `T` (Linux apt list; macOS `pod install`; Windows toolchain preflight, delegated to `build_apps.py --check`) | `release.yml:132`, `ci.yml:121`, `release.yml:56` |
| `ci.py verify` | `flutter pub get` → `flutter analyze` → `flutter test -j 1`, all three phases always run, failures accumulated (R-4) | `ci.yml:37-43`, `64-70`, `91-97` |
| `ci.py build --target T [--release]` | `flutter pub get` if stale, then **invokes `scripts/build_apps.py` with the flag set declared in `scripts/ci/targets.py`** — including `--fetch-native` for windows | `ci.yml:125`, `release.yml:60/102/138` |
| `ci.py assert-capabilities --target T` | Runs the R-7 assertion suite against the built artefact for `T` (§4.5) | *new — nothing today* |
| `ci.py package --target T --version V` | Produces the one platform archive at the canonical name, using `shutil`/`zipfile`/`tarfile` from the stdlib — one implementation, three platforms | `release.yml:63-66`, `:105`, `:141-144` |
| `ci.py release-preflight --version V` | Validates that every expected archive exists at the exact path `action-gh-release` will glob, and prints it. Satisfies the contract's "release.yml 的驗證以 CI 可驗證的方式進行，不實際發版" clause without pushing a tag | *new* |
| `ci.py --print-plan --target T` | Dry-run: prints the exact argv of every command each subcommand would execute, and exits 0 without executing. §4.8 | *new* |

**Non-goal for the command surface:** `ci.py` never re-implements anything `build_apps.py`
already does. If a behaviour exists in `build_apps.py`, `ci.py` calls it. A capability appearing
in both files is a defect.

### 4.2 Module layout

```
scripts/ci.py                 # argparse dispatch only, ~150 lines, no logic
scripts/ci/__init__.py
scripts/ci/targets.py         # DATA: per-target build flags, artifact paths, archive names,
                              #       provision steps. No target-specific code lives elsewhere.
scripts/ci/run.py             # subprocess wrapper: list argv only, shell=False, RC self-captured
scripts/ci/phases.py          # provision / verify / build / package implementations
scripts/ci/assertions.py      # R-7 suite runner (wraps check_dng_ffi_artifacts.py's logic)
scripts/ci/report.py          # artifact log writing, RC capture, summary emission
```

`targets.py` is the R-3 answer: it is the single place where "windows also needs
`--fetch-native`" or "linux needs `ninja-build libgtk-3-dev`" is stated. Adding a platform is a
dict entry. `phases.py` must contain no `if target == ...`.

### 4.3 What stays in YAML, what moves to Python

**Stays in YAML** (AC3's explicit exemption for 環境動作):
- `actions/checkout@v4` — both of them (§5.1).
- `subosito/flutter-action@v2` with the pinned version, plus its `cache: true`.
- `actions/cache` blocks (R-8).
- `softprops/action-gh-release@v2` (credential-bearing API upload).
- `on:`/`permissions:`/`defaults: run: working-directory: Halcyon`/matrix declarations.

**Moves to Python:** everything else. After the rewrite, a job body is:

```yaml
      - run: python3 scripts/ci.py provision --target ${{ matrix.target }}
      - run: python3 scripts/ci.py verify
      - run: python3 scripts/ci.py build --target ${{ matrix.target }}
      - run: python3 scripts/ci.py assert-capabilities --target ${{ matrix.target }}
```

Mechanical statement of AC3, checkable by grep: **no `run:` block in either workflow contains
more than one line, and every one of them begins `python3 scripts/ci.py`** — with the sole
exception of steps that are themselves `uses:` actions.

### 4.4 Matrix and fail-fast (R-4)

`ci.yml`'s three analyze/test jobs collapse into:

```yaml
  verify:
    strategy:
      fail-fast: false
      matrix:
        os: [macos-14, windows-latest, ubuntu-latest]
    runs-on: ${{ matrix.os }}
```

`release.yml`'s three jobs likewise become one matrix over `(os, target)` with
`fail-fast: false`. The comment block at `release.yml:14-19` — recording that
`continue-on-error: true` was removed by explicit user instruction because a job that cannot
fail tells you nothing — **must be carried over verbatim into the rewritten file**. `fail-fast:
false` is not `continue-on-error`: it lets sibling jobs finish, it does not let a job pass while
failing. That distinction must be stated in the new file's header so a future reader does not
"clean up" one into the other.

### 4.5 Capability assertions per platform artefact (R-7)

The suite runs against the **built artefact**, never against build outputs' existence or the
build's exit code. Each assertion is a declared record carrying ceyx's five mandatory fields —
`measures`, `valid_on`, `why_valid`, `red_state`, `expected` — and the runner **rejects** an
assertion missing any of them (`Spec_build_rewrite.md:893-909`).

| id | Measures | Method | Valid on | Notes |
|---|---|---|---|---|
| `H-ARCH` | the app binary's machine architecture equals the target's declared arch | `lipo -archs` (Mach-O) / ELF header (Linux) / PE header machine field (Windows) | all, per-format instrument | macOS is arm64-only *by design* — `build_apps.py` already fails the build on a missing x86_64 native slice (PL-6 note, `build_apps.py:155-159`) **[V]**. This assertion makes that fact visible in every run, not just the failing one |
| `H-DECODER-PRESENT` | the ceyx decoder library is present inside the packaged bundle, at the path the app will `DynamicLibrary.open` | file presence in the *archive*, not the build tree | all | The failure this catches is the one `ceyx_release_pin.json:14-16` describes: a Windows install missing `heif.dll` or `libde265.dll` fails at `DynamicLibrary.open` with an error naming only the decoder **[V]** |
| `H-DECODER-DEPS` | on Windows, all three DLLs (`dng_decoder_native.dll`, `heif.dll`, `libde265.dll`) are in the archive together | archive inventory vs. `ceyx_release_pin.json`'s windows list | windows | Reads the pin file as data — never a hardcoded list (R-1a/R-1c) |
| `H-DECODER-HASH` | each placed ceyx library's SHA-256 equals the pin | `hashlib` | linux, windows | `build_apps.py` already enforces this at fetch time; asserting it again *on the packaged artefact* is the difference between "we downloaded the right bytes" and "we shipped the right bytes" |
| `H-SIZED-SYMBOL` | `dng_decode_and_process_sized` is reachable in the shipped decoder | **see OQ-1** — currently symbol-table presence via `nm`/`dumpbin` (`check_dng_ffi_artifacts.py:53-76`) | **macos, linux confirmed valid; windows validity UNRESOLVED** | This is the R-7 trap, stated openly rather than papered over. Symbol-table presence is a *proxy*, valid on Mach-O/ELF by their permissive default visibility and structurally different on PE. Escalated as **OQ-1** rather than silently adopted |
| `H-BUNDLE-RUNS` | the built app starts and exits cleanly (`--version`-style smoke) | subprocess launch with a timeout | **DEFERRED** — see OQ-2 | A GUI Flutter app has no headless entry point today. Listed so its absence is a recorded gap, not an oversight |

**Red-state demonstration is a delivery requirement** (ceyx R-7's check clause, and this repo's
own 2026-08-27 lesson): each assertion's `red_state` recipe must be executed once and observed
red before the migration is signed off. A gate never seen to fail is not evidence. Concretely:
delete one of the three Windows DLLs from a staging copy and confirm `H-DECODER-DEPS` fails;
corrupt one byte and confirm `H-DECODER-HASH` fails.

**`check_dng_ffi_artifacts.py`'s `skipped` semantics must be tightened.** Today a missing
inspection tool yields `symbol=skipped`, counted but not failing (`check_dng_ffi_artifacts.py:117-130`)
**[V]**. That is correct for a *manual multi-platform* checker run from one host. It is wrong for
a CI gate running **on the artefact's own platform**, where the tool's absence is an environment
defect, not a legitimate skip. In `ci.py assert-capabilities`, a skip on the native platform is a
**failure**; skips remain legitimate only for cross-platform artefacts. This is a direct instance
of 2026-08-25's lesson: a silently-skipped gate produces a green report indistinguishable from a
full run — so the runner must additionally **print one explicit `SKIP: <id> — <reason>` line per
skipped assertion**, and the summary must state the skipped count.

### 4.6 Exit codes, logging, and RC self-capture

Non-negotiable, encoding lessons 2026-08-23 and 2026-08-28:

1. **Every subprocess is invoked with a list argv and `shell=False`.** No `shell=True` anywhere
   in `scripts/ci/` (the two pre-existing `build_apps.py` sites are the declared PL-3 deviation).
2. **Exit codes come from `CompletedProcess.returncode` only.** Never from a pipeline, never
   from `${PIPESTATUS[n]}` (which does not expand in every shell — 2026-08-23), never from a
   harness notification (which lies in both directions — 2026-08-23).
3. **No `| grep` in any argv.** Tool output is captured to a `str` and matched in Python. Under
   `set -o pipefail`, `nm | grep -q PATTERN` inverts: grep exits early on a *match*, `nm` takes
   SIGPIPE, the pipeline returns 141, and a *present* symbol reports as failure (2026-08-28).
   In Python with `capture_output=True` this family is structurally impossible.
4. **Every phase writes an artifact log** to `build/ci-logs/<target>-<phase>.txt` whose **last
   line is `RC=<n>`, captured inside the file by the producing process**, not by the caller and
   not by the CI harness.
5. **`ci.py verify` accumulates**: analyze failing does not skip tests (R-4). One non-zero exit
   at the end, with a summary naming every failed phase.
6. **The summary is machine-checkable**: a final `CI-SUMMARY: <target> phases=<n> failed=<n>`
   line, so AC4's `gh run list` verdict can be cross-checked against the artefact's own claim
   rather than trusted alone.
7. **`gh run list --json conclusion` returns an empty string, not null, for in-progress runs**
   (2026-08-28) — any status-polling helper must compare against the literal string, per AC4's
   "判空顯式比對字串".

### 4.7 Windows shell policy (R-5)

Three mechanical rules, each greppable:

1. **No `shell: bash` in any job whose `runs-on` matches `windows-*`.** Current state already
   complies **[V]**; the rewrite must add the check so it stays true.
2. **Windows steps run under `pwsh`** (the runner default) and contain exactly one line:
   `python3 scripts/ci.py <subcommand> ...`. Values containing drive letters never pass through a
   shell that could rewrite them.
3. **`ci.py` asserts at startup** that on `os.name == "nt"` the running interpreter is native
   Windows Python — `pathlib.Path(sys.executable).drive` must be non-empty and `sys.executable`
   must not contain `/usr/bin`. An MSYS Python would reintroduce the entire path-mangling family
   through the back door.

Paths are constructed with `pathlib` and passed as `os.fspath(Path(...).resolve())`. No
string-concatenated paths in the argv renderer.

### 4.8 `--print-plan`: shortening the write-to-discover distance

Because platform is a *parameter* and argv rendering is a *pure function*,
`python3 scripts/ci.py --print-plan --target windows` prints the exact Windows argv from a macOS
laptop, with no Windows host. This is ceyx's §8.1 mechanism, and it is the single cheapest
defence available given that "cannot verify Windows locally" is a first-class constraint here
too. A golden-file test asserts the rendered argv for all five targets; any flag regression is
caught pre-commit on any host. Two zero-cost lints run over the rendered Windows argv: every
path-typed element matches `^[A-Za-z]:[\\/]`, and no element begins with `/`.

**What this does not prove [I]:** nothing here establishes Windows *runtime* behaviour. It
eliminates the flag/path families locally; the rest still needs a real runner.

---

## 5. Halcyon-specific constraints (AC1's third clause)

### 5.1 Sibling ceyx checkout — load-bearing, must survive

`pubspec.yaml` declares `ceyx: path: ../ceyx/plugin`, so a bare root-level checkout can never
`pub get`. Both workflows therefore check out **two** repos side by side under the workspace and
run every step from `Halcyon/` via `defaults: run: working-directory: Halcyon`
(`ci.yml:1-15`, `release.yml:3-6`) **[V]**. Both files carry a comment saying "don't 'simplify'
this back".

Requirements on the rewrite:
- Both `checkout@v4` steps stay in YAML in every job, including any new matrix job.
- `defaults: run: working-directory: Halcyon` stays; `ci.py` additionally resolves the repo root
  from its own on-disk location (the pattern `check_dng_ffi_artifacts.py:98-103` already uses)
  **[V]**, so it behaves identically regardless of invocation cwd.
- The "don't simplify this back" comments are **carried over verbatim** into the rewritten files.
- `ci.py` must fail with a *named* error ("sibling ceyx checkout not found at <resolved path>")
  when `../ceyx/plugin` is absent, rather than letting `flutter pub get` produce an opaque
  resolution error. This is the single most likely first-round CI failure mode.
- **The `jhangyu/ceyx` checkout is unpinned** — no `ref:` on `ci.yml:26-29` or
  `release.yml:42-45` **[V]**, so every run takes ceyx's default branch tip. Flagged as
  **OQ-3**: pinning it is arguably required by 載體中立, but pinning is itself a pin change.

### 5.2 `ceyx_release_pin.json` — read as data, never edited

The pin fixes both *which release* (tag) and *which bytes* (per-asset SHA-256), because a tag can
be moved and an asset re-uploaded (`ceyx_release_pin.json:3-8`) **[V]**. Only two things may
write it: a human, or `python3 scripts/build_apps.py --ceyx-release latest`, which resolves the
newest release, records real digests, and **stops without building** so a maintainer reviews the
diff (`ceyx_release_pin.json:18-23`) **[V]**.

Requirements: `ci.py` **reads** this file (for `H-DECODER-DEPS`/`H-DECODER-HASH`) and never
writes it. No CI job invokes `--ceyx-release latest`. The Windows `--fetch-native` flag is
preserved with its rationale comment (`release.yml:96-101`).

**Contradiction found — reported, not adapted (§7, C-1):** the provenance comment reads "pin
moved to **v0.1.4** on 2026-08-30" while the same sentence cites the download URL
`.../releases/download/**v0.1.5**/<asset>` and the file's `tag` field is `"v0.1.5"`
(`ceyx_release_pin.json:25-27`, `:39`) **[V]**. Two of the three say v0.1.5. This is almost
certainly a prose typo in the comment, but the pin's whole value is that it is auditable, so a
maintainer must confirm — and per 載體中立 **this spec changes nothing**, including the typo.

### 5.3 `build_apps.py` — the single entry point, preserved

`build_apps.py` is the sole build entry point and workflows must never call `flutter build`
directly (`release.yml:8-9`) **[V]**. It replaced `build.sh`, `build_windows.ps1` and
`build_windows.py`, which are deleted; a per-platform script must not be reintroduced (CLAUDE.md).

Requirements: `ci.py build` is a **thin delegator**. It resolves the flag set from
`scripts/ci/targets.py` and execs `build_apps.py`; it does not reimplement any phase, does not
parse `build_apps.py`'s internals, and does not bypass it for any target. Its colour-gate
refusal semantics (a run whose correctness gate never executed must not report success — `--no-colour-gate`
is the loud opt-out and that run exits 2, per CLAUDE.md and `build_apps.py:120-127`) are
preserved: `ci.py` must propagate exit code 2 as a failure and must never pass `--no-colour-gate`.

### 5.4 macOS is arm64-only, deliberately

The vendored `libdng_decoder_native.dylib` is arm64-only, so a universal app's x86_64 slice would
link without the native decoder — and `ld` only *warns* about that, which is how it went
unnoticed (`build_apps.py:155-159`) **[V]**. `verify_macos_slices()` now fails the build.
`H-ARCH` (§4.5) is the CI-visible restatement. The rewrite must not add an x86_64 or universal
macOS target.

### 5.5 Coverage gap, stated as a fact not a proposal

`ci.yml` builds **only macOS** (`ci.yml:99-125`) **[V]**. Windows and Linux *builds* are exercised
only by `release.yml`, which fires solely on a `v*` tag push (`release.yml:23-24`) **[V]**. So on
a normal PR, a change that breaks the Windows or Linux build is invisible until a release tag.
Closing this is not in the contract's in-scope list; it is recorded as **PL-5**, and the design
above (one matrix, one command surface) makes closing it a one-line matrix edit later.

---

## 6. Ordering constraint

R-7 before R-8, without exception — ceyx R-7's note that caching "must never be traded against
R-7" means the assertions must be landed and demonstrated red *before* any cache can make a
stale artefact fast. Concretely: `assert-capabilities` lands and shows a red state before
`actions/cache` is introduced. Detailed sequencing belongs to `Plan_ci_rewrite.md` (AC2).

---

## 7. Non-goals / out-of-scope

Reproduced from the contract (§0) and expanded with this spec's own exclusions:

1. **ceyx's own build rewrite** — separate contract.
2. **Any third-party pin change** — 載體中立. Includes `ceyx_release_pin.json` values,
   `flutter-version: '3.44.6'`, `pubspec.lock`, and every `build_apps.py` flag default.
3. **App source behaviour changes** — only CI/build-script changes are permitted.
4. **Actually cutting a release tag** — `release.yml` is validated via `ci.py release-preflight`
   under `workflow_dispatch`, without publishing.
5. **Rewriting `build_apps.py`** — it is called, not replaced (§5.3).
6. **Converting `package_windows.sh`** — a macOS-hosted developer hand-off tool, outside the CI
   path (PL-1).
7. **Adopting vcpkg/Conan** — R-1 does not apply (§3).
8. **Containerising Linux/Android** — R-6 does not apply in its strong form (§3).
9. **Fixing the two `build_apps.py` `shell=True` sites** — PL-3.
10. **Adding Windows/Linux build coverage to PR CI** — PL-5.

### Parking lot

| id | Item |
|---|---|
| PL-1 | `package_windows.sh` → Python. Not CI, not urgent, but it is the last non-trivial shell script in `scripts/` |
| PL-2 | R-2's unmet clauses (committed binaries in ceyx; macOS excluded from the pin) — ceyx-side |
| PL-3 | `build_apps.py:631` and `:674` `shell=True` (cmd.exe, not MSYS). Not R-5's family; audited (S6) but worth eliminating |
| PL-4 | Containerised Linux CI, if a Linux-only environment-dependent failure ever appears |
| PL-5 | Windows/Linux **build** jobs in PR CI, not only on release tags |
| PL-6 | `ceyx_release_pin.json` provenance comment says v0.1.4 while tag and URL say v0.1.5 (§5.2, C-1) |

---

## 8. Open questions requiring user decision

Listed, not silently decided.

**OQ-1 — Is symbol-table presence an acceptable instrument for `H-SIZED-SYMBOL` on Windows?**
`check_dng_ffi_artifacts.py` measures whether `dng_decode_and_process_sized` appears in the
decoder's symbol table (`check_dng_ffi_artifacts.py:53-76`) **[V]**. ceyx spent two CI rounds
learning that this exact instrument is valid on Mach-O/ELF *by coincidence* (permissive default
visibility) and structurally invalid on Windows PE (`Spec_build_rewrite.md:855-865`). Halcyon's
DLL is built by ceyx with an explicit export list, so the check may well be genuinely valid
here — but "may well be" is what burned ceyx.
Options: **(a)** promote it as-is on all three platforms and accept the risk; **(b)** promote it
on macOS/Linux and mark Windows `valid_on`-excluded until a red state is demonstrated on a real
Windows runner; **(c)** replace it with a functional probe (a tiny Dart/FFI program that
`DynamicLibrary.open`s the shipped library and looks up the symbol) — tests the capability
directly on every platform, at the cost of building and running a probe in CI.
**Recommendation: (c)**, falling back to **(b)** if the probe proves awkward inside a Flutter
bundle. The whole point of R-7 is that the proxy is what fails.

**OQ-2 — Should `H-BUNDLE-RUNS` exist?** Asserting the packaged app actually launches would catch
the class of failure where every symbol is present and the bundle is still unusable (missing
runtime DLL, bad rpath). A Flutter GUI app has no headless entry point today, so this needs
either a `--smoke-test` flag in the app or a windowing-capable CI runner. Cost is real; the gap
is real. **Recommendation: defer, record as a known gap** — but the user should confirm, because
"builds green, ships broken" is exactly what R-7 exists to prevent.

**OQ-3 — Should the `jhangyu/ceyx` checkout be pinned to a ref?** Today it is unpinned
(`ci.yml:26-29`, `release.yml:42-45`) **[V]**, so every CI run compiles Halcyon's Dart against
whatever ceyx's default branch happens to be. That is a live reproducibility hole and arguably a
violation of 載體中立's spirit. But adding a `ref:` *is itself a pin change*, which the contract
forbids during migration. **Recommendation: leave unpinned in this rewrite** (behaviour-preserving),
raise it immediately afterwards. User confirmation needed because a mid-migration ceyx breakage
would be indistinguishable from a rewrite defect — and that ambiguity would poison the CI loop
AC4/AC5 depend on.

**OQ-4 — Matrix collapse vs. explicit jobs for `release.yml`.** Collapsing three release jobs
into one matrix removes ~60 lines of duplication and enables `fail-fast: false` uniformly, but it
makes per-platform steps (`pod install` on macOS only; `--fetch-native` on Windows only)
conditional. This spec pushes those into `ci.py provision`/`targets.py` so the YAML stays
uniform — but that means a macOS-only step now runs (as a no-op) on all three.
**Recommendation: collapse.** Uniform YAML with per-target data is the design R-3 asks for.
Flagged because it is the one place where "behaviour-preserving" and "unified" pull apart.

---

## 9. Acceptance self-check against AC1

| AC1 clause | Where | Status |
|---|---|---|
| Spec file exists | this file | ✅ |
| R-1..R-8 each with 適用/不適用 + reason | §3, one row per requirement including R-1a/R-1b/R-1c | ✅ 11 verdicts, no silence |
| Sibling ceyx checkout constraint covered | §5.1 | ✅ |
| `ceyx_release_pin` constraint covered | §5.2 | ✅ + one contradiction reported (C-1) |
| `build_apps.py` single entry point covered | §5.3, §2.2, §4.1 | ✅ |
| Verbatim contract quote | §0 | ✅ end-state + AC1..AC6 + out-of-scope |
| Current-state inventory with fate, as a table | §2.1 (22+20 steps), §2.2 (all 9 script paths) | ✅ |
| Target design | §4 | ✅ |
| Non-goals | §7 | ✅ |
| Open questions listed not decided | §8 | ✅ 4 questions |
