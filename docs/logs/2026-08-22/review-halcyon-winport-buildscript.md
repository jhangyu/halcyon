# Review — `windows-port` build tooling slot (`buildscript`)

> Reviewer slot: `buildscript` (Team A, contract `docs/logs/2026-08-22/windows-port-review-contract.md`).
> Scope (mine alone): `windows-port:scripts/windows/build_windows.py` (624 lines, new) and
> `scripts/package_windows.sh` (9 lines changed).
> Read-only review. Nothing was built, nothing was merged, `build_windows.py` was **not** executed
> (Windows-only, this host is macOS).
> Raw evidence: `tmp/verify/buildscript-*.txt|md|py`.

Citation convention: `bw.py:N` = `windows-port:scripts/windows/build_windows.py` line N.
`pkg.sh:N` = `scripts/package_windows.sh` line N (post-change numbering, branch `windows-port`).

---

## Verdict

**MERGE-AFTER-BLOCKERS** — 2 blockers, 9 should-fix, 6 nits.

Both blockers are behavioural, and the contract (user decision #2) already schedules
`build_windows.py` for deletion in favour of `scripts/build_apps.py`. The actionable form of every
finding below is therefore: **`build_apps.py` must not reproduce it**. Do not patch the old file
(contract red line, line 55).

Overall assessment of the artifact as committed: the script is well above average for a one-off
port script. Failure paths mostly `fail()` loudly with actionable hints, phases map to numbered
runbook sections, and the two hardest Windows-specific problems (`vcvars64` injection without a
Native Tools prompt; `.bat` launch) are solved correctly and are the main reason it succeeded where
`build_windows.ps1` did not. The defects are concentrated in **what it declares success on**, not in
what it does.

---

## Blockers

### [BLOCKER] B1 — Exits 0 and places the DLL when the correctness gate was never run
`bw.py:514-537`, `bw.py:616-620`, runbook `docs/logs/2026-08-21/windows-ffi-build-runbook.md:130-137`

Runbook S4 is explicit about ordering: *"Once `build-windows\dng_decoder_native.dll` exists **and the
native test suite … at minimum `test_cfa_color` and any color accuracy tests) passes on this
machine**"* → then copy the DLL into `dng_processor_ffi/windows/Libraries/`.

The script inverts that gate. With no `--cfa-sample-dng`:
- `bw.py:526` emits `warn("colour gate skipped: no --cfa-sample-dng given.")`;
- `bw.py:532-537` copies the DLL into place **unconditionally**;
- `bw.py:616-620` prints `DONE with N warning(s)` and `main()` returns → **exit code 0**.

There is no `--strict`, no non-zero exit for warnings, and no acknowledgement flag. The script's own
docstring (`bw.py:4-9`) claims *"Faithful transcription … if something the runbook prescribes is
missing, it stops and says so instead of routing around it."* This is exactly a route-around of a
runbook-prescribed gate, and it is the one gate that separates "compiled" from "correct".

This is not hypothetical — it already happened. `windows-port:docs/logs/2026-08-22/windows-port-changes.md:9,26`
records `EXIT=0`, `DONE with 2 warning(s)`, one of which is the skipped colour gate; and per the
contract's shared ground truth the resulting 1,906,688-byte DLL was then **committed** to
`flutter_dng_decoder` as a prebuilt. An artifact that no gate ever validated entered git under a
green exit code.

Note the ordering *is* correct when a sample is supplied: `bw.py:514-524` builds and runs
`test_cfa_color` **before** `bw.py:532` places the DLL, so a gate failure aborts before placement.
The defect is solely the no-sample path.

Required in `build_apps.py`: skipping the colour gate must either (a) exit non-zero, (b) require an
explicit `--no-colour-gate` acknowledgement flag, or (c) refuse to place the DLL. Silence-as-success
is the one thing this script must not inherit.

### [BLOCKER] B2 — `import winreg` at module top level makes the file non-importable off Windows
`bw.py:38`

`import winreg` sits in the unconditional import block. On macOS/Linux the script dies with
`ModuleNotFoundError: No module named 'winreg'` before `argparse` runs — so even `--help` fails, and
there is no `sys.platform` guard anywhere in the file. That is defensible for a Windows-only script
delivered in a Windows zip.

It is a blocker **for the port**, because contract A4 requires `python3 scripts/build_apps.py --help`
to exit 0 on this macOS host while covering the `windows` target. Any transcription of the registry
/ vcvars logic into `build_apps.py` must lazy-import `winreg` inside the Windows branch, and the
script must assert `sys.platform` before entering platform-specific phases.

---

## Should-fix

### [SHOULD-FIX] S1 — Halide v21 (321 MB) is fetched with **zero** integrity verification
`bw.py:42-44`, `bw.py:244-266`, `bw.py:285-336`

What is verified: nothing. `urllib.request.urlretrieve` (`bw.py:257`) validates the TLS certificate
chain (CPython default `ssl.create_default_context`), and `urlretrieve` raises `ContentTooShortError`
on a `Content-Length` mismatch, which `bw.py:258` catches into `fail()`. That is the entire integrity
story.

What is **not** verified: no SHA-256, no size assertion, no signature, no verification that the
extracted `Halide.lib` corresponds to `HALIDE_COMMIT`. `HALIDE_COMMIT` (`bw.py:42`) is used **only**
to build the asset filename (`bw.py:43`) — it is a naming convention, not a content anchor. GitHub
release assets are mutable by anyone with push rights to the repo: an asset can be deleted and
re-uploaded under the same name, and this script would accept it silently.

Blast radius: Halide is a code generator whose AOT output is statically linked into
`dng_decoder_native.dll`, which is then **committed into git** as a redistributable prebuilt. A
substituted Halide distribution is a direct path into a shipped binary.

Rating: **SHOULD-FIX (high)**, not blocker, because (a) TLS + a pinned release tag + a pinned asset
name is the same trust model the runbook's documented manual fallback (`bw.py:262-264`) already
relies on, and (b) the fix is one `hashlib.sha256` comparison. **Promote to BLOCKER if you regard the
committed DLL as a redistributable artifact** — for a build that produces a checked-in binary,
pinning the hash is the normal bar.

Also in this function:
- **Stale-version drift is undetectable.** The presence guard is `halide_lib.exists()` only
  (`bw.py:287-290`). A leftover Halide v20 tree with a `lib/Halide.lib` is accepted silently and
  reported `[ok] already present`. The `VERSION` file the script itself writes (`bw.py:328-334`) is
  never read back. Fix: read `VERSION`, compare against `HALIDE_ASSET`, re-fetch on mismatch.
- **A corrupt-but-complete zip crashes with a traceback**, not a `fail()`. `extract_halide`'s
  `zipfile.ZipFile(zip_path)` (`bw.py:273`) is outside any `try` — `BadZipFile` escapes `main()`.
- **`top = tops[0]`** (`bw.py:303-306`) silently picks an arbitrary directory if the archive ever has
  more than one top-level entry (`iterdir()` order is filesystem order). Assert `len(tops) == 1`.
- **No socket timeout** on the download. A stalled connection hangs forever with no output, since
  the progress reporter only prints every 200 blocks (`bw.py:253`).
- **No zip-slip risk** — I checked rather than assumed. `zipfile.ZipFile.extract` sanitises
  traversal: `'../../evil.txt'` extracts to `out/evil.txt`. Evidence:
  `tmp/verify/buildscript-python-probes.txt` PROBE2. Not a finding; recorded so nobody re-raises it.

### [SHOULD-FIX] S2 — MSVC environment is accepted without any architecture check
`bw.py:155-158`, `bw.py:432`

`ensure_msvc_env` short-circuits on `if os.environ.get("INCLUDE") and os.environ.get("LIB"): return True`.
Any non-empty pair passes. An **x86** (or ARM64) Native Tools Command Prompt sets both, so the script
prints `[ok] MSVC environment (INCLUDE/LIB) present` (`bw.py:432`) and proceeds to build a 32-bit
toolchain.

Nothing downstream pins the architecture either — I checked the preset rather than assuming:
`flutter_dng_decoder/dng_processor/native/CMakePresets.json` `windows-vulkan` has **no**
`architecture` or `toolset` field; it sets only generator Ninja, `clang-cl`, `MultiThreaded` CRT, and
its own description says *"Run from a Developer Command Prompt / after **vcvars64.bat**"*. The
architecture comes entirely from the ambient environment this function just rubber-stamped.

The failure is loud but late: linking x86 objects against `%VULKAN_SDK%\Lib\vulkan-1.lib` (x64, the
only path checked, `bw.py:439`) produces an `lld-link` machine-type mismatch — after a full native
compile. Cheap fix: assert `os.environ.get("VSCMD_ARG_TGT_ARCH") == "x64"`, or probe
`clang-cl --version` for the target triple.

### [SHOULD-FIX] S3 — `refresh_env_from_registry` inverts PATH precedence and does not expand `%VARS%`
`bw.py:113-131`

Two problems:

1. **Precedence inversion** (`bw.py:120-125`). The list is built as `[current]`, then machine is
   `insert(0)` and user `insert(1)`, yielding `machine;user;current`. The **inherited shell PATH ends
   up last**. Anyone who deliberately front-loaded a toolchain in their shell — e.g. the standalone
   LLVM that `README_WINDOWS.md:36` explicitly offers as an alternative to the VS clang component —
   gets silently overridden by whatever the machine-wide PATH resolves first. `which("clang-cl")`
   (`bw.py:400`) then reports a path the user did not choose, and the `[ok]` line makes it look
   intentional. Normal precedence is `process > user > machine`.
2. **REG_EXPAND_SZ is not expanded.** `winreg.EnumValue` (`bw.py:104`) returns REG_EXPAND_SZ values
   verbatim; the machine `Path` typically contains `%SystemRoot%\system32;%SystemRoot%;…`. Those
   entries are injected literally and are inert for `shutil.which`. Fix: `os.path.expandvars` per
   entry. *(Documented CPython behaviour; not machine-verified on this macOS host — flagged as such.)*

Neither is fatal, but both mean the "refreshed" environment is not the environment the user believes
they are in — which is the class of bug that costs a session to diagnose.

### [SHOULD-FIX] S4 — Required-tool checks that degrade instead of failing
Answering the lead's question directly, these are the silent-degrade paths I found:

| Path | Line | Behaviour | Should be |
|---|---|---|---|
| `cmake --version` return code unchecked | `bw.py:414-417` | `subprocess.run` without `check=`/returncode test; unparseable output → `warn(...)` and **continue past the ≥3.14 gate** | `fail()` — an unreadable cmake version means the version gate did not run |
| `vulkaninfo` "check" never runs vulkaninfo | `bw.py:444-448` | Present → `[ok] … (run it manually …)`. Absent → `warn`. Either way the Vulkan 1.1+ requirement is never actually checked | run it and parse `apiVersion`, or drop the check and say so in the runbook |
| `ffi_lib_dir` created rather than validated | `bw.py:367`, `bw.py:532` | Phase 0 validates `Halcyon/`, `flutter_dng_decoder/`, `native/` (`bw.py:369-378`) but **not** `dng_processor_ffi/windows/`. Phase 1 `mkdir(parents=True)` fabricates it. A wrong/old decoder tree gets a DLL in a directory CMake never reads; the only symptom is Phase 2's "not bundled" diagnostic (`bw.py:556-577`), which points at `generated_plugins.cmake` and stale CMake caches — **never at the real cause** | add `ffi_lib_dir.parent` to the Phase 0 existence loop |
| `locate_vs_install` / `ensure_msvc_env` catch only `OSError` | `bw.py:149`, `bw.py:178` | `subprocess.TimeoutExpired` (timeouts of 30 s / 120 s are set) is **not** an `OSError` → uncaught traceback instead of the intended graceful `return None`/`False` → the actionable `fail()` hint at `bw.py:391-398` is never printed | catch `subprocess.SubprocessError` too |
| `vswhere -latest -products *` | `bw.py:145` | No `-requires …VC.Tools.x86.x64`. If the newest VS lacks the C++ workload but an older one has it, the script fails with "could not establish an MSVC environment" while a usable install sits on disk | add `-requires`, and `-prerelease` if relevant |

### [SHOULD-FIX] S5 — `run_checked`: output is not actually streamed; stdin is not closed
`bw.py:213-224`

`bufsize=1` is combined with `universal_newlines=False`, i.e. **binary mode**. Python does not
line-buffer in binary mode; it emits `RuntimeWarning: line buffering (buffering=1) isn't supported in
binary mode, the default buffer size will be used` and falls back to block buffering. Verified on
this host: `tmp/verify/buildscript-python-probes.txt` PROBE1 (Python 3.14.4).

Consequence: the `for line in proc.stdout` loop (`bw.py:222`) still yields lines, but only after each
~8 KB block arrives — so a 20-minute native build looks stalled in chunks rather than progressing.
For a script whose whole job is to be watchable by a human on a laptop, that matters. Fix:
`text=True, encoding=…, errors="replace", bufsize=1` (and then `decode_bytes` is unnecessary), or
drop `bufsize=1` and stop pretending.

Also: no `stdin=subprocess.DEVNULL`. Child processes inherit the console; anything that prompts
(a first-run `flutter` consent prompt, a cmd.exe `Terminate batch job (Y/N)?`) can block the build
with its prompt buried in a block-buffered stream.

**Exit-code propagation is fine** — `proc.stdout` is fully drained before `proc.wait()` (`bw.py:222-224`),
which is the correct order and cannot deadlock, and `cmd /c foo.bat` propagates the batch errorlevel.
The changes doc reports this empirically confirmed (`windows-port:docs/logs/2026-08-22/windows-port-changes.md:64`:
a real `flutter pub get` exit 1 surfaced as `ERROR in Phase 2 … (exit code 1)` and `EXIT=1`). I found
nothing contradicting that.

### [SHOULD-FIX] S6 — `shell=True` + argv list leaves cmd.exe metacharacters unescaped
`bw.py:211-221`

`subprocess.list2cmdline` implements the **C runtime / `CommandLineToArgvW`** quoting rules. It does
**not** escape `cmd.exe` metacharacters (`& | ^ < > %`). Verified on this host:

```
list2cmdline(["flutter","build","a&calc b","%PATH%"])  ->  flutter build "a&calc b" %PATH%
```
(`tmp/verify/buildscript-python-probes.txt` PROBE3). `%PATH%` came through completely unquoted and
will be expanded by `cmd.exe`; `&` inside a quoted token is safe *here* only because
`list2cmdline` happened to quote that token for the space it contains — a `&`-bearing token without
whitespace would not be quoted at all.

**Not currently reachable.** The only `shell=True` call sites are the two `flutter` invocations
(`bw.py:550`, `bw.py:551`), whose arguments are hard-coded literals; every user-controlled argument
(`--cfa-sample-dng` → `bw.py:524`, `--native-target` → `bw.py:488`) goes to a `.exe`, hence
`shell=False`. So this is a **latent** hazard, not a live vulnerability: the first future `.bat` call
that forwards a user path (a path containing `&` is legal on Windows) turns into command injection
with no code change to `run_checked`.

I am explicitly **not** proposing a return to `subprocess.run(["cmd.exe","/c", …])` with an argv list
— the handover's §9 "禁止重踩" table rules that out with evidence, and this is a different code path
in any case. The correct hardening is to escape `cmd` metacharacters with `^` (or shell-quote) before
`list2cmdline` sees them, for `.bat`/`.cmd` targets only.

### [SHOULD-FIX] S7 — "every phase is idempotent" is asserted in the one place it is false
`bw.py:231`, `README_WINDOWS.md:82`, `windows-port:docs/logs/2026-08-22/windows-port-changes.md:75-76`

Every `run_checked` failure prints the hint *"Re-running this script after a fix is safe: every phase
is idempotent."* The changes doc, describing this same branch, says the opposite for the change this
same branch makes:

> **改 target 名後必須刪掉 `Halcyon/build/windows` 重新 configure**，CMake 不會就地更新已快取的
> `$<TARGET_FILE_DIR:...>` generator expression（實測：不清就報 `No target "photo_selector_flutter"`）。

The script has no `--clean`, never deletes `Halcyon/build/windows`, never runs `flutter clean`, and
never detects a cache whose target name predates the rename. So the exact scenario this branch
creates — anyone who built Halcyon on Windows before the `photo_selector_flutter` → `halcyon` rename
— hits `No target "photo_selector_flutter"`, and the script's failure hint tells them to just re-run.
Misdirection during a failure is what produces re-tread sessions.

Practical blast radius is limited for the zip workflow (source-only extract, no `build/` exists), but
the script is now also committed **in-repo**, where a stale `build/windows` is the normal state.

Per-phase idempotency, since the lead asked:

| Phase | Re-runnable? | Half-state on failure |
|---|---|---|
| 0 prerequisites `bw.py:362-469` | Yes, pure checks | None |
| 0b Halide `bw.py:474-475` | Yes, **except** stale-version drift (S1) and an interrupt between `Halide.lib` landing and `VERSION` being written (`bw.py:325-334`) short-circuits the guard forever | Merged tree from `copytree(dirs_exist_ok=True)` (`bw.py:312`); stale files from an older Halide are never purged |
| 1 configure `bw.py:482` | Yes for a matching cache; **No** across a target rename or a moved source dir | `build-windows/` cache left inconsistent; human must delete it |
| 1 build + place `bw.py:495-537` | Yes | DLL stays placed if Phase 2 later fails — benign and desirable |
| 2 flutter `bw.py:550-585` | Yes | Partial `build/windows` tree; recovery is `flutter clean`, which the script never offers |
| `--native-target` `bw.py:484-493` | Yes | Returns early — **skips the warning summary entirely** (`bw.py:616-620`), so warnings raised in Phase 0 vanish |

### [SHOULD-FIX] S8 — The nasm `[warn]` is asserted non-blocking without evidence, against a byte-exact contract
`bw.py:450-454`, `windows-port:docs/logs/2026-08-22/windows-port-changes.md:23`

The warn text and the changes doc both state SIMD-off is *"只影響效能，不影響正確性"* / "optional, safe
to defer". That claim is asserted, never tested, and it sits next to a project that maintains an
explicitly **byte-exact colour contract** — `bw.py:407` mandates clang-cl over cl.exe precisely
because `-ffp-contract=off` is required for it, and the preset description repeats this.

Concretely: the delivered Windows DLL was built with libjpeg-turbo `WITH_SIMD=OFF` (nasm was
installed at `C:\Program Files\NASM` but not on PATH), while the macOS/Android builds presumably use
their SIMD paths. Whether libjpeg-turbo's SIMD and C decode paths are bit-identical for the
colour-space conversions this pipeline uses is **the** question, and I could not determine it from
this host — see "Could not determine" below. The honest position is that the warn should say
"may cause cross-platform output divergence, unverified", not "safe to defer".

Second-order note: the superseded handover §11 predicted nasm would be auto-detected on the next
clean run; the changes doc records that prediction as **falsified** (`:24-25`). The script offers no
help — it neither searches the standard install location nor tells the user which directory to add.

### [SHOULD-FIX] S9 — `package_windows.sh`: the pack ships a Python entry point that its own README never mentions
`pkg.sh:10,103,107,170,178,199-200`, `scripts/windows/README_WINDOWS.md:13,25,35-42,49-62,82`

The 9-line change is purely additive in mechanics: add `build_windows.py` to the layout comment
(`:10`), define `PY_SRC` (`:103`), assert it exists (`:107`), `cp` it to the zip root (`:170`),
update one `step` label (`:178`), and reword the closing "next:" instruction (`:199-200`) so
`build_windows.py` is listed first with *"(no Native Tools prompt needed)"*. Nothing is removed and
nothing else in the pack changes.

The problem is that `README_WINDOWS.md` was **not** updated on this branch (`git diff --stat
main...windows-port -- scripts/windows/README_WINDOWS.md` is empty; evidence
`tmp/verify/buildscript-refs.txt`), while `pkg.sh:198` still tells the user *"read README_WINDOWS.md"*.
So the recipient gets contradictory instructions:

- The prerequisites table (`README:35-42`) has **no Python row** — yet the now-primary entry point is
  a Python 3 script. Nothing in the pack states a Python version requirement. This is the concrete
  "does the pack still contain everything the Windows machine needs" answer: **no** — it ships a
  dependency it never declares.
- `README:35,49` still says run everything from an **x64 Native Tools Command Prompt**; the console
  output now says the opposite for the `.py`.
- `README:13,25,52,59,62` document only `build_windows.ps1`, including its switch names
  (`-CfaSampleDng`, `-SkipFlutterBuild`) rather than the Python ones (`--cfa-sample-dng`,
  `--skip-flutter-build`), and `README:25` credits the `.ps1` with the Halide download.
- `README:82` repeats the idempotency claim S7 disproves.
- `README:13` still lists the zip layout without `build_windows.py` (`pkg.sh:10` was updated;
  the README's copy of the same layout block was not).

Negative space for `package_windows.sh` (contract A2): **no existing behaviour is removed**. Two
forward dependencies are created that the merge must account for:

1. `[ -f "$PS1_SRC" ] || fail` (`pkg.sh:105`) is still a **hard** requirement. Contract line 39
   schedules `build_windows.ps1` for deletion at merge time — doing so breaks
   `package_windows.sh` immediately. Whoever deletes the `.ps1` must delete `pkg.sh:102,105,169,178`
   in the same commit.
2. Provenance inconsistency, now doubled. `pkg.sh:17-22` states the pack is `git archive HEAD`, i.e.
   *committed content only*; but `pkg.sh:169,170` `cp` both scripts from the **working tree**. A
   locally-modified `build_windows.py` ships at the zip root while the *committed* version also ships
   at `Halcyon/scripts/windows/build_windows.py` (it is tracked, so `git archive` carries it). The
   zip therefore contains two copies of the file that can differ, under a header claiming they cannot.
   Pre-existing for the `.ps1`; the change doubles the exposure.

---

## Nits

- **[NIT]** `bw.py:456` — `which("flutter") or which("flutter.bat")`: the fallback result is stored in
  `flutter_exe` and then **never used**. Phase 2 calls `run_checked("flutter", …)` (`bw.py:550`), which
  re-resolves independently at `bw.py:211`. In practice `PATHEXT` makes `which("flutter")` find
  `flutter.BAT` so the fallback is dead code, but the pattern (validate one path, execute another) is
  the bug shape to avoid: resolve once, pass the resolved path.
- **[NIT]** `bw.py:384` — the W9 preset check is a raw substring test `'"windows-vulkan"' not in presets_text`
  against JSON text; it would also match the string inside a `configurePreset` back-reference or a
  comment. Parse the JSON (`json.load` + name lookup) — the file is already known to be JSON.
- **[NIT]** `bw.py:419-421` — the two-group regex fallback yields a 2-tuple compared against `(3, 14)`;
  fine today, but `(3, 14) < (3, 14, 0)` is `True`, so a hypothetical exact "3.14" print would pass
  while "3.14.0" also passes — harmless, but the comparison is not what it looks like.
- **[NIT]** `bw.py:294-314` — peak disk during Phase 0b is roughly 3× the distribution (zip + staged
  extract + final copy, ~1 GB) in `%TEMP%`, which is frequently on a different, smaller volume than
  the project. Extract straight into the destination instead of staging then `copytree`.
- **[NIT]** Line references in the authoritative changes doc are already stale:
  `windows-port:docs/logs/2026-08-22/windows-port-changes.md:62` cites the two `.bat` call sites as
  `:538/:539`; they are at `bw.py:550/551`. Its §6 heading cites `:200-224` for `run_checked`, which
  spans `:200-234`. Minor, but the doc is billed as the authoritative rationale.
- **[NIT]** `bw.py:538-540` prints "this extracted tree is not a git checkout" **unconditionally** —
  including when the script is run from the real in-repo checkout, where it is false and the git steps
  it declines to run are exactly the right ones.

---

## Portability inventory for `build_apps.py` (contract A6, my slice)

Every capability in `windows-port:scripts/windows/build_windows.py`.
`MUST-PORT` = behaviour must exist in `build_apps.py` (possibly generalised).
`WINDOWS-ONLY` = keep, but confined to the Windows branch.
`DROP` = deliberately do not carry over.
Rows tagged **+FIX** carry a finding above and must not be transcribed verbatim.

| # | Capability | `bw.py` ref | Verdict | Note for the port |
|---|---|---|---|---|
| 1 | `--root` (pack layout `<root>/Halcyon` + `<root>/flutter_dng_decoder`) | :344, :357, :364-366 | MUST-PORT (reshape) | In-repo the decoder is `../flutter_dng_decoder`. Mirror `package_windows.sh`'s `--decoder DIR` flag name rather than inventing a third convention |
| 2 | `--cfa-sample-dng` | :345, :468-469, :514-524 | MUST-PORT | Keep the early existence check at :468 (fails before a 20-min build) |
| 3 | `--skip-flutter-build` | :346, :545-546 | MUST-PORT | Generalise to `--native-only` |
| 4 | `--native-target TARGET...` | :347, :484-493 | MUST-PORT | Iteration aid, cheap, genuinely useful. Fix the early `return` that skips the warning summary |
| 5 | `phase()/step()/ok()/warn()/fail(hints=[])` logging | :50-77 | MUST-PORT | The `fail(hints=…)` pattern is the best thing in this file — every failure names the phase and 1-3 concrete next actions. Keep verbatim in spirit |
| 6 | `WARNING_COUNT` + end-of-run summary | :46, :65-68, :616-620 | MUST-PORT **+FIX** | Add `--strict` / non-zero exit; see B1. Must also fire on the `--native-target` early-return path |
| 7 | `decode_bytes` (utf-8 → mbcs → replace) | :80-88 | MUST-PORT (simplify) | If `run_checked` moves to `text=True` (S5), this disappears entirely except for the `mbcs` fallback, which is Windows-only and `LookupError`-guarded already |
| 8 | `_read_registry_env` | :96-110 | WINDOWS-ONLY | Lazy-import `winreg` (B2) |
| 9 | `refresh_env_from_registry` | :113-131 | WINDOWS-ONLY **+FIX** | Fix PATH precedence and `%VAR%` expansion (S3) |
| 10 | `locate_vs_install` (vswhere) | :134-152 | WINDOWS-ONLY **+FIX** | Add `-requires …VC.Tools.x86.x64`; catch `SubprocessError` (S4) |
| 11 | `ensure_msvc_env` (vcvars64 → env injection) | :155-194 | WINDOWS-ONLY **+FIX** | **The single highest-value capability in the file** — it is why no Native Tools prompt is needed. Must survive. Add the x64 assertion (S2). Keep the `shell=True` single-string form; handover §9 forbids reverting to the argv-list form |
| 12 | `run_checked` (stream + fail-fast + hints) | :200-234 | MUST-PORT **+FIX** | Fix `bufsize`/text mode, add `stdin=DEVNULL`, pass the already-resolved exe (S5, nit 1) |
| 13 | `.bat`/`.cmd` → `shell=True` routing | :211-220 | WINDOWS-ONLY **+FIX** | Required for `flutter.bat`; no-op on macOS/Linux. Escape cmd metacharacters (S6) |
| 14 | `which()` wrapper | :237-238 | MUST-PORT | Trivial; keep |
| 15 | Sibling-layout existence check | :369-378 | MUST-PORT **+FIX** | Add `dng_processor_ffi/<platform>/Libraries` parent to the loop (S4) |
| 16 | CMake preset presence check (W9 gate) | :380-389 | MUST-PORT (generalise) | Per-platform preset name; parse JSON not substring (nit 2). The "do not hand-invent a preset, report back" stance is worth keeping |
| 17 | `clang-cl` mandatory check | :400-409 | WINDOWS-ONLY | macOS/Android use their own toolchains; the `-ffp-contract=off` rationale in the hint is worth preserving in the message |
| 18 | CMake ≥ 3.14 check | :411-422 | MUST-PORT **+FIX** | Check the return code; `fail()` on unparseable output (S4) |
| 19 | Ninja presence check | :424-430 | WINDOWS-ONLY | Tied to the preset's generator; re-derive per platform preset rather than hard-coding |
| 20 | `VULKAN_SDK` + `Lib/vulkan-1.lib` check | :434-442 | WINDOWS-ONLY | macOS is Metal; Android gets Vulkan via the NDK |
| 21 | `vulkaninfo` advisory | :444-448 | DROP (or make real) | As written it never checks anything (S4). Either run it and parse `apiVersion`, or delete and leave it to the runbook |
| 22 | nasm / `WITH_SIMD` warning | :450-454 | MUST-PORT **+FIX** | Keep the warn; change the wording to admit the cross-platform parity question is unverified (S8). Consider probing `C:\Program Files\NASM` and telling the user what to add to PATH |
| 23 | `flutter` presence check, `--skip-flutter-build` interaction | :456-466 | MUST-PORT | The "missing is fine *because* you asked to skip" branch (:458-459) is good design; keep it |
| 24 | Halide fetch + extract + install | :244-336 | MUST-PORT **+FIX** | See S1 in full: pin sha256, read back `VERSION`, wrap `BadZipFile`, assert one top-level dir, add a socket timeout |
| 25 | Skip `share/doc/*` during extraction | :269-282 | WINDOWS-ONLY | MAX_PATH workaround; also the reason the `.ps1` died (handover §9). Documenting *why* matters more than the code |
| 26 | Mirror `lib/Release/Halide.lib` → `lib/Halide.lib` | :316-323 | WINDOWS-ONLY | Multi-config layout quirk of the v21 Windows asset only |
| 27 | Write `third_party/halide/VERSION` provenance stamp | :328-334 | MUST-PORT | Good practice; make it load-bearing by reading it back (S1) |
| 28 | `cmake --preset <platform>` configure | :482 | MUST-PORT | |
| 29 | `cmake --build --preset … --target dng_decoder_native` | :495-500 | MUST-PORT | |
| 30 | Assert the built shared library exists | :502-512 | MUST-PORT | Generalise `.dll` / `.dylib` / `.so`; keep the "check the ninja output for where it actually went" hint |
| 31 | `test_cfa_color` build + run (colour gate) | :514-524 | MUST-PORT **+FIX** | **B1.** Placement and exit code must depend on it |
| 32 | Place the library into `dng_processor_ffi/<platform>/Libraries/` | :532-537 | MUST-PORT | Per-platform destination |
| 33 | "not a git checkout, commit the DLL yourself" advisory | :538-540 | DROP (replace) | In-repo `build_apps.py` can detect a real checkout; print the git commands only when running from a source-only extract (nit 6) |
| 34 | `flutter pub get` | :550 | MUST-PORT | |
| 35 | `flutter build <platform> --release` | :551 | MUST-PORT | This is where `scripts/build.sh`'s per-target flags must merge in |
| 36 | Assert the native library is bundled next to the app | :553-578 | MUST-PORT | Per-platform artifact path. The refusal to hand-copy the DLL as a workaround (:576) is a deliberate anti-workaround stance — keep it |
| 37 | `generated_plugins.cmake` / stale-cache diagnostics | :556-573 | WINDOWS-ONLY | Directly encodes the `bundled_libraries` silent-typo class of failure; high value, keep in the Windows branch |
| 38 | Report the produced runner artifact(s) | :580-585 | MUST-PORT | Contract A5 requires the produced artifact path to be reported — this is that mechanism |
| 39 | Phase 3 manual verification protocol (26 print lines) | :587-612 | MUST-PORT (condensed) | Contains the user's hard 1-second first-decode gate and the "cold-launch every measurement / do not average it away" rules. Do not silently drop it; condense to a pointer plus the gate statement |
| 40 | Top-level `import winreg`, no `sys.platform` guard | :38 | **DROP** | B2 — must be lazy-imported; `--help` must work on every host |
| 41 | *(absent)* Developer-Mode / symlink-support pre-check | — | **NEW** | Flutter on Windows requires symlink support; per the changes doc (`:95`) this blocked Phase 2 for a whole session and was resolved by the user manually. A one-line pre-check belongs in Phase 0 |
| 42 | *(absent)* `--clean` / stale-target-name detection | — | **NEW** | S7 — the `photo_selector_flutter` → `halcyon` rename requires deleting `build/windows`; nothing automates or detects it |
| 43 | *(absent)* Host-OS assertion before platform phases | — | **NEW** | A cross-platform entry point must reject `build_apps.py windows` on macOS with one clear line |

---

## Could not determine

1. **Whether libjpeg-turbo `WITH_SIMD=OFF` is output-identical to the SIMD path** for this pipeline's
   decode/colour-conversion routes. This decides whether the S8 warn is truly benign or a
   cross-platform byte-exactness divergence. Requires running the two builds and comparing decoded
   output — not possible from this macOS host and not possible without the Windows machine.
2. **Runtime behaviour of the `shell=True` `.bat` path on Windows.** I verified `list2cmdline`'s
   escaping on macOS (PROBE3, platform-independent string function) and reasoned about `cmd /c`
   semantics from documentation; I did not execute a `.bat` on Windows. Exit-code propagation is
   corroborated by the changes doc's reported real failure, not by my own run.
3. **`winreg` REG_EXPAND_SZ non-expansion (S3.2)** is documented CPython behaviour, not verified on a
   machine.
4. **Whether the Halide v21 release asset's bytes today match what was downloaded on the Windows
   machine.** No hash was recorded on either side, which is precisely finding S1.
5. **Whether `build_windows.py` runs correctly at all** — I did not execute it (Windows-only; red
   line). All findings are static plus the documented evidence in
   `windows-port:docs/logs/2026-08-22/windows-port-changes.md`.

---

## Verdict (repeat)

**MERGE-AFTER-BLOCKERS** for `windows-port:scripts/windows/build_windows.py` and
`scripts/package_windows.sh`.

Blockers: B1 (green exit + DLL placement with the colour gate never run), B2 (top-level `winreg`
import — blocking for the `build_apps.py` port, not for the Windows-only file in isolation).

Given user decision #2, the practical resolution is that `build_apps.py` must satisfy B1 and B2 and
the S-series findings, and `build_windows.py` is deleted at merge — in which case
`package_windows.sh:102,105,169,178` (the `.ps1` hard requirement) must be cleaned up in the same
commit, and `README_WINDOWS.md` must gain a Python prerequisite row (S9).

VERDICT: MERGE-AFTER-BLOCKERS
