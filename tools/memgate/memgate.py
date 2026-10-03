"""D5 memory gate (memory-reclamation campaign, plan section 6).

Subcommands:
  manifest  --corpus <dir> --out <json>         freeze the corpus (sha256 per file)
  native    --dll-dir <dir> --prereg <md> --out <dir> --label <name> [...]
            headless decode of the frozen corpus through the app's FFI entry,
            then the app's idle funnel, then a 12 s in-process wait; samples
            GPU Total Committed, PrivateBytes and write-combine regions.
  compare   --base <dir> --cand <dir> --prereg <md> [--out <file>]
  detach    --out <dir> -- <subcommand args...>   run a subcommand in a
            windowless detached supervisor that appends PROCESS_RC=<n> to
            <out>/result.md when the child exits (crash included).

Judged metrics are ONLY GPU `Total Committed` (tc_mib), process PrivateBytes
(pb_mib) and write-combine region walks (wc_*). Working Set and GPU Local
Usage are never read.

Expected values come from the caller's pre-registration file, section
`## Expected values`, one per line:
  - EXPECT <id>: <expr> <op> <number>     judged; any FAIL -> MEMGATE_RC=1
  - REPORT <id>: <expr>                   printed, never judged
<expr> is arithmetic (+ - * / unary -) over numbers and metric keys:
  native: <sample>.<metric>          e.g. idle.tc_mib
  compare: base.<sample>.<metric> / cand.<sample>.<metric>
samples: pre_decode, peak, after_decode, idle
metrics: tc_mib, pb_mib, wc_total_mib, wc_max_region_mib, wc_count_ge_16,
         wc_count_ge_256, decode_errors, decodes, and tc_mib_getcounter (the
         independent Get-Counter reading; pre_decode/after_decode/idle only)
"""
import argparse
import ast
import ctypes as C
import ctypes.wintypes as W
import datetime
import hashlib
import json
import operator
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
HALCYON_ROOT = os.path.dirname(os.path.dirname(HERE))
MANIFEST_PATH = os.path.join(HERE, "corpus_manifest.json")
CREATE_NO_WINDOW = 0x08000000
DETACHED_PROCESS = 0x00000008
CREATE_NEW_PROCESS_GROUP = 0x00000200
CREATE_BREAKAWAY_FROM_JOB = 0x01000000
YUV420 = 1
MIB = float(1 << 20)
SAMPLES = ("pre_decode", "peak", "after_decode", "idle")
METRICS = ("tc_mib", "pb_mib", "wc_total_mib", "wc_max_region_mib",
           "wc_count_ge_16", "wc_count_ge_256", "decode_errors", "decodes")


class GateError(Exception):
    pass


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="milliseconds")


def run_quiet(argv, timeout=120):
    """Run a child windowless; return (rc, stdout, stderr)."""
    r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                       creationflags=CREATE_NO_WINDOW, encoding="utf-8", errors="replace")
    return r.returncode, r.stdout, r.stderr


# --------------------------------------------------------------------------
# Pre-registration and expectation language
# --------------------------------------------------------------------------

EXPECT_RE = re.compile(r"^\s*-\s*EXPECT\s+([A-Za-z0-9_.-]+)\s*:\s*(.+?)\s*(>=|<=|==|>|<)\s*(-?[0-9.]+)\s*$")
REPORT_RE = re.compile(r"^\s*-\s*REPORT\s+([A-Za-z0-9_.-]+)\s*:\s*(.+?)\s*$")
OPS = {">=": operator.ge, "<=": operator.le, "==": operator.eq, ">": operator.gt, "<": operator.lt}


def read_prereg(path):
    """Return (text, sha256, expects, reports). Refuses a prereg with no judged expectation."""
    if not path or not os.path.isfile(path):
        raise GateError("REFUSED: pre-registration file missing: %r" % path)
    raw = open(path, "rb").read()
    text = raw.decode("utf-8")
    m = re.search(r"^## Expected values\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        raise GateError("REFUSED: pre-registration has no '## Expected values' section: %s" % path)
    expects, reports = [], []
    for line in m.group(1).splitlines():
        e = EXPECT_RE.match(line)
        if e:
            expects.append((e.group(1), e.group(2), e.group(3), float(e.group(4))))
            continue
        r = REPORT_RE.match(line)
        if r:
            reports.append((r.group(1), r.group(2)))
    if not expects:
        raise GateError("REFUSED: '## Expected values' holds no EXPECT line (a gate with no "
                        "judged expectation passes vacuously): %s" % path)
    return text, hashlib.sha256(raw).hexdigest(), expects, reports


_BINOPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv}


def _dotted(node):
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if not isinstance(node, ast.Name):
        raise GateError("bad expression term")
    parts.append(node.id)
    return ".".join(reversed(parts))


def eval_expr(expr, values):
    """Evaluate arithmetic over dotted metric keys. Unknown key -> GateError."""
    def ev(n):
        if isinstance(n, ast.Expression):
            return ev(n.body)
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)):
            return float(n.value)
        if isinstance(n, ast.BinOp) and type(n.op) in _BINOPS:
            return _BINOPS[type(n.op)](ev(n.left), ev(n.right))
        if isinstance(n, ast.UnaryOp) and isinstance(n.op, ast.USub):
            return -ev(n.operand)
        if isinstance(n, (ast.Attribute, ast.Name)):
            key = _dotted(n)
            if key not in values or values[key] is None:
                raise GateError("unknown or absent metric key %r" % key)
            return float(values[key])
        raise GateError("disallowed expression element %s" % type(n).__name__)
    return ev(ast.parse(expr, mode="eval"))


def judge(expects, reports, values):
    """Return (lines, rc). rc=0 iff every EXPECT passes."""
    lines, rc = [], 0
    for tid, expr, op, thr in expects:
        try:
            v = eval_expr(expr, values)
            ok = OPS[op](v, thr)
            lines.append("MEMGATE_TARGET %s value=%.1f threshold=%s%g verdict=%s   [%s]"
                         % (tid, v, op, thr, "PASS" if ok else "FAIL", expr))
            rc |= 0 if ok else 1
        except GateError as e:
            lines.append("MEMGATE_TARGET %s value=ERROR threshold=%s%g verdict=FAIL   [%s] (%s)"
                         % (tid, op, thr, expr, e))
            rc = 1
    for tid, expr in reports:
        try:
            lines.append("MEMGATE_TARGET %s value=%.1f verdict=REPORT   [%s]" % (tid, eval_expr(expr, values), expr))
        except GateError as e:
            lines.append("MEMGATE_TARGET %s value=ERROR verdict=REPORT   [%s] (%s)" % (tid, expr, e))
    lines.append("MEMGATE_RC=%d" % rc)
    return lines, rc


# --------------------------------------------------------------------------
# Corpus manifest
# --------------------------------------------------------------------------

def cmd_manifest(a):
    old = json.load(open(MANIFEST_PATH, encoding="utf-8")) if os.path.isfile(MANIFEST_PATH) else {}
    excluded = old.get("excluded", {})
    files = {}
    for name in sorted(os.listdir(a.corpus)):
        p = os.path.join(a.corpus, name)
        if not os.path.isfile(p) or name in ("README.md", ".halcyon_status.json") or name in excluded:
            continue
        files[name] = sha256_file(p)
    out = {"corpus_root": os.path.abspath(a.corpus), "excluded": excluded, "files": files}
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, indent=1, sort_keys=True)
        f.write("\n")
    return 0


def verify_corpus(manifest, corpus):
    """Return list of problems; empty == OK."""
    problems = []
    for name, digest in sorted(manifest["files"].items()):
        p = os.path.join(corpus, name)
        if not os.path.isfile(p):
            problems.append("missing %s" % name)
        elif sha256_file(p) != digest:
            problems.append("sha256 mismatch %s" % name)
    return problems


# --------------------------------------------------------------------------
# User prefs store guard (plan risk R11): an app-layer run must leave
# %APPDATA%\jhangy.us\Halcyon\ byte-identical, or the M3 migration trigger
# ("new store empty") would never fire for the user.
# --------------------------------------------------------------------------

def user_store_dir():
    return os.path.join(os.environ["APPDATA"], "jhangy.us", "Halcyon")


def store_snapshot(root):
    """{'exists': bool, 'files': {relpath: sha256}} for every file under root."""
    if not os.path.isdir(root):
        return {"exists": False, "files": {}}
    files = {}
    for dp, _dn, fn in os.walk(root):
        for n in fn:
            p = os.path.join(dp, n)
            files[os.path.relpath(p, root).replace("\\", "/")] = sha256_file(p)
    return {"exists": True, "files": files}


def store_diff(before, after):
    """List of changes; empty == store unchanged."""
    out = []
    if before["exists"] != after["exists"]:
        out.append("directory exists %s -> %s" % (before["exists"], after["exists"]))
    for k in sorted(set(before["files"]) | set(after["files"])):
        b, a = before["files"].get(k), after["files"].get(k)
        if b != a:
            out.append("%s %s" % ("added" if b is None else "removed" if a is None else "modified", k))
    return out


# --------------------------------------------------------------------------
# Windows probes: GPU Total Committed (PDH), PrivateBytes, write-combine walk
# --------------------------------------------------------------------------

class MBI(C.Structure):
    _fields_ = [("BaseAddress", C.c_void_p), ("AllocationBase", C.c_void_p), ("AllocationProtect", W.DWORD),
                ("PartitionId", W.WORD), ("RegionSize", C.c_size_t), ("State", W.DWORD),
                ("Protect", W.DWORD), ("Type", W.DWORD)]


def wc_walk():
    """Private committed PAGE_WRITECOMBINE regions of this process (= Halide Vulkan
    blocks on the Arc iGPU, final-report.md section 1)."""
    k32 = C.windll.kernel32
    k32.VirtualQuery.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t]
    k32.VirtualQuery.restype = C.c_size_t
    addr, mbi, tot, regions = 0, MBI(), 0, []
    while k32.VirtualQuery(C.c_void_p(addr), C.byref(mbi), C.sizeof(mbi)):
        if mbi.State == 0x1000 and mbi.Type == 0x20000 and (mbi.Protect & 0x400):
            tot += mbi.RegionSize
            if mbi.RegionSize >= 16 << 20:
                regions.append(round(mbi.RegionSize / MIB, 1))
        addr = (mbi.BaseAddress or 0) + mbi.RegionSize
        if addr >= 1 << 47:
            break
    return round(tot / MIB, 1), sorted(regions, reverse=True)


class PMC(C.Structure):
    _fields_ = [("cb", W.DWORD), ("PageFaultCount", W.DWORD)] + \
               [(n, C.c_size_t) for n in ("PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
                                          "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
                                          "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage",
                                          "PrivateUsage")]


def private_bytes_mib():
    k32 = C.windll.kernel32
    k32.GetCurrentProcess.restype = W.HANDLE
    k32.K32GetProcessMemoryInfo.argtypes = [W.HANDLE, C.c_void_p, W.DWORD]
    c = PMC()
    c.cb = C.sizeof(c)
    if not k32.K32GetProcessMemoryInfo(k32.GetCurrentProcess(), C.byref(c), c.cb):
        raise GateError("GetProcessMemoryInfo failed")
    return round(c.PrivateUsage / MIB, 1)


class PdhValue(C.Structure):
    _fields_ = [("CStatus", W.DWORD), ("pad", W.DWORD), ("largeValue", C.c_longlong)]


PDH_MORE_DATA = 0x800007D2
PDH_FMT_LARGE = 0x00000400


def gpu_total_committed(pid):
    """Sum of `GPU Process Memory(pid_<pid>_*)\\Total Committed` over all adapter
    instances, read through PDH. Returns (mib, instance_count, per_instance)."""
    pdh = C.windll.pdh
    pattern = "\\GPU Process Memory(pid_%d_*)\\Total Committed" % pid
    n = W.DWORD(0)
    st = pdh.PdhExpandWildCardPathW(None, pattern, None, C.byref(n), 0) & 0xFFFFFFFF
    if st not in (0, PDH_MORE_DATA) or n.value == 0:
        return 0.0, 0, {}
    buf = C.create_unicode_buffer(n.value + 2)
    st = pdh.PdhExpandWildCardPathW(None, pattern, buf, C.byref(n), 0) & 0xFFFFFFFF
    if st != 0:
        raise GateError("PdhExpandWildCardPathW failed 0x%08X" % st)
    paths = [p for p in C.wstring_at(C.addressof(buf), n.value).split("\0") if p]
    if not paths:
        return 0.0, 0, {}
    hq = C.c_void_p()
    if pdh.PdhOpenQueryW(None, None, C.byref(hq)) != 0:
        raise GateError("PdhOpenQueryW failed")
    try:
        hcs = []
        for p in paths:
            hc = C.c_void_p()
            st = pdh.PdhAddEnglishCounterW(hq, p, None, C.byref(hc)) & 0xFFFFFFFF
            if st != 0:
                raise GateError("PdhAddEnglishCounterW(%s) failed 0x%08X" % (p, st))
            hcs.append((p, hc))
        st = pdh.PdhCollectQueryData(hq) & 0xFFFFFFFF
        if st != 0:
            raise GateError("PdhCollectQueryData failed 0x%08X" % st)
        per, tot = {}, 0
        for p, hc in hcs:
            v = PdhValue()
            st = pdh.PdhGetFormattedCounterValue(hc, PDH_FMT_LARGE, None, C.byref(v)) & 0xFFFFFFFF
            if st != 0:
                raise GateError("PdhGetFormattedCounterValue(%s) failed 0x%08X" % (p, st))
            per[p.split("(")[1].split(")")[0]] = round(v.largeValue / MIB, 1)
            tot += v.largeValue
        return round(tot / MIB, 1), len(paths), per
    finally:
        pdh.PdhCloseQuery(hq)


def gpu_total_committed_getcounter(pid):
    """Independent cross-check reader (Get-Counter, the I2 harness's reader), windowless."""
    ps = ("$s=(Get-Counter -ErrorAction SilentlyContinue "
          "'\\GPU Process Memory(pid_%d_*)\\Total Committed').CounterSamples;"
          "$t=0; foreach($c in $s){$t+=$c.CookedValue}; '{0:F1}' -f ($t/1MB)") % pid
    rc, out, err = run_quiet(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps], timeout=90)
    txt = out.strip().replace(",", "")
    try:
        return float(txt), rc
    except ValueError:
        return None, rc


def take_sample(name, t0, cross_check=False):
    pid = os.getpid()
    tc, ninst, per = gpu_total_committed(pid)
    wc_tot, regions = wc_walk()
    s = {"name": name, "t_s": round(time.perf_counter() - t0, 2), "at": now(),
         "tc_mib": tc, "tc_instances": ninst, "tc_per_instance": per,
         "pb_mib": private_bytes_mib(), "wc_total_mib": wc_tot, "wc_regions_mib": regions}
    if cross_check:
        s["tc_mib_getcounter"], s["getcounter_rc"] = gpu_total_committed_getcounter(pid)
    return s


def derive(s):
    r = s["wc_regions_mib"]
    d = {"tc_mib": s["tc_mib"], "pb_mib": s["pb_mib"], "wc_total_mib": s["wc_total_mib"],
         "wc_max_region_mib": max(r) if r else 0.0,
         "wc_count_ge_16": len(r), "wc_count_ge_256": sum(1 for x in r if x >= 256.0)}
    if "tc_mib_getcounter" in s:
        d["tc_mib_getcounter"] = s["tc_mib_getcounter"]
    return d


# --------------------------------------------------------------------------
# PE exports (provenance)
# --------------------------------------------------------------------------

def pe_exports(path):
    d = open(path, "rb").read()
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    optsz = struct.unpack_from("<H", d, pe + 20)[0]
    opt = pe + 24
    ddir = opt + (112 if struct.unpack_from("<H", d, opt)[0] == 0x20B else 96)
    erva = struct.unpack_from("<I", d, ddir)[0]
    secs = []
    so = opt + optsz
    for i in range(nsec):
        vsz, va, rsz, rp = struct.unpack_from("<IIII", d, so + 40 * i + 8)
        secs.append((va, max(vsz, rsz), rp))

    def off(rva):
        for va, sz, rp in secs:
            if va <= rva < va + sz:
                return rva - va + rp
        raise GateError("rva outside sections")
    if not erva:
        return []
    e = off(erva)
    _nfun, nnam, _af, an, _ao = struct.unpack_from("<IIIII", d, e + 20)
    out = []
    for i in range(nnam):
        nr = struct.unpack_from("<I", d, off(an) + 4 * i)[0]
        o = off(nr)
        out.append(d[o:d.index(b"\0", o)].decode())
    return out


# --------------------------------------------------------------------------
# native layer
# --------------------------------------------------------------------------

class DngResult(C.Structure):
    _fields_ = [("rgba_data", C.c_void_p), ("width", C.c_int32), ("height", C.c_int32),
                ("error_code", C.c_int32), ("decode_ms", C.c_double), ("process_ms", C.c_double)]


def redirect_native_stdio(path):
    """Give the process valid std handles pointing at a file BEFORE the decoder DLL
    loads, so native stderr lines ([IdleFunnel] markers) land in the artifact even
    under pythonw / no-handle launch."""
    f = open(path, "ab", buffering=0)
    import msvcrt
    h = msvcrt.get_osfhandle(f.fileno())
    k32 = C.windll.kernel32
    k32.SetStdHandle.argtypes = [W.DWORD, W.HANDLE]
    k32.SetStdHandle(W.DWORD(-11 & 0xFFFFFFFF), h)
    k32.SetStdHandle(W.DWORD(-12 & 0xFFFFFFFF), h)
    os.dup2(f.fileno(), 1)
    os.dup2(f.fileno(), 2)
    return f


def pin_libraries(pin_ref):
    """sha256 per Windows x64 decoder library from scripts/ceyx_release_pin.json at <pin_ref>."""
    rc, out, err = run_quiet(["git", "-C", HALCYON_ROOT, "show", "%s:scripts/ceyx_release_pin.json" % pin_ref])
    if rc != 0:
        raise GateError("git show pin at %s failed rc=%d %s" % (pin_ref, rc, err.strip()[:200]))
    d = json.loads(out)
    return d.get("tag"), {lib["artifact"]: lib["sha256"] for lib in d["assets"]["windows"]["libraries"]}


def git_head(repo):
    rc, out, _ = run_quiet(["git", "-C", repo, "rev-parse", "HEAD"])
    return "%s RC=%d" % (out.strip() or "?", rc)


class Result:
    """result.md writer: appended and flushed section by section, so the
    pre-registration is physically on disk before the first sample exists."""

    def __init__(self, path):
        self.f = open(path, "w", encoding="utf-8", newline="\n", buffering=1)

    def w(self, *lines):
        for ln in lines:
            self.f.write(ln + "\n")
        self.f.flush()
        os.fsync(self.f.fileno())


def cmd_native(a):
    os.makedirs(a.out, exist_ok=True)
    res = Result(os.path.join(a.out, "result.md"))
    log = open(os.path.join(a.out, "native.log"), "w", encoding="utf-8", buffering=1)

    def P(*x):
        log.write(" ".join(str(i) for i in x) + "\n")
    rc_total = 0
    try:
        res.w("# D5 native run: %s" % a.label, "", "started %s pid %d" % (now(), os.getpid()), "")
        text, digest, expects, reports = read_prereg(a.prereg)
        res.w("## 1. Pre-registration (verbatim, copied before any measurement)", "",
              "file: %s" % os.path.abspath(a.prereg), "sha256: %s" % digest, "copied_at: %s" % now(), "",
              "```", text.rstrip("\n"), "```", "")

        # 2. provenance
        manifest = json.load(open(a.manifest, encoding="utf-8"))
        corpus = a.corpus or manifest["corpus_root"]
        problems = verify_corpus(manifest, corpus)
        res.w("## 2. Provenance", "", "corpus: %s" % corpus,
              "corpus_manifest: %s sha256 %s" % (a.manifest, sha256_file(a.manifest)),
              "corpus_check: %s" % ("OK (%d files)" % len(manifest["files"]) if not problems
                                    else "FAIL " + "; ".join(problems)))
        if problems:
            raise GateError("corpus manifest mismatch: " + "; ".join(problems))
        bindir = os.path.join(a.out, "bin")
        os.makedirs(bindir, exist_ok=True)
        dlls = sorted(n for n in os.listdir(a.dll_dir) if n.lower().endswith(".dll"))
        if "dng_decoder_native.dll" not in dlls:
            raise GateError("dng_decoder_native.dll not in --dll-dir")
        hashes = {}
        for n in dlls:
            shutil.copy2(os.path.join(a.dll_dir, n), os.path.join(bindir, n))
            hashes[n] = sha256_file(os.path.join(bindir, n))
            res.w("dll_sha256 %s %s" % (hashes[n], n))
        if a.pin_ref:
            tag, pinned = pin_libraries(a.pin_ref)
            bad = [n for n, h in pinned.items() if hashes.get(n) != h]
            res.w("pin_check ref=%s tag=%s %s" % (a.pin_ref, tag,
                  "OK (%d libraries equal the pin)" % len(pinned) if not bad else "FAIL " + ",".join(bad)))
            if bad:
                raise GateError("loaded DLLs differ from pin %s: %s" % (a.pin_ref, bad))
        else:
            res.w("pin_check: not requested (--pin-ref absent)")
        exports = pe_exports(os.path.join(bindir, "dng_decoder_native.dll"))
        ceyx_exports = [e for e in exports if e.startswith("ceyx_")]
        has_funnel_counters = "ceyx_debug_idle_funnel_counters" in exports
        res.w("exports_total %d" % len(exports), "exports_ceyx %s" % " ".join(ceyx_exports),
              "ceyx_debug_idle_funnel_counters: %s" % ("present" if has_funnel_counters else "absent"),
              "halcyon HEAD: %s" % git_head(HALCYON_ROOT),
              "ceyx HEAD: %s" % git_head(a.ceyx_repo),
              "params: threads=%d passes=%d seed=%d floor=%d idle_wait_s=%g output_format=yuv420(1)"
              % (a.threads, a.passes, a.seed, a.floor, a.idle_wait), "")

        # load DLL from the copy, with native stdio routed into the artifact
        stdio = redirect_native_stdio(os.path.join(a.out, "native_stderr.log"))
        os.add_dll_directory(os.path.abspath(bindir))
        d = C.CDLL(os.path.join(os.path.abspath(bindir), "dng_decoder_native.dll"))
        d.ceyx_probe_output_size_format.argtypes = [C.c_char_p, C.c_int32, C.c_int32, C.POINTER(C.c_int32),
                                                    C.POINTER(C.c_int32), C.POINTER(C.c_int64)]
        d.ceyx_probe_output_size_format.restype = C.c_int32
        d.ceyx_decode_into_buffer_format.restype = C.POINTER(DngResult)
        d.ceyx_decode_into_buffer_format.argtypes = [C.c_char_p, C.c_int32, C.c_void_p, C.c_size_t,
                                                     C.c_int32, C.c_void_p]
        d.dng_free_result.argtypes = [C.POINTER(DngResult)]
        d.ceyx_native_idle_shrink.argtypes = [C.c_int32]
        d.ceyx_native_idle_shrink.restype = C.c_int64

        t0 = time.perf_counter()
        files = []
        for name in sorted(manifest["files"]):
            p = os.path.join(corpus, name).encode()
            w, h, b = C.c_int32(), C.c_int32(), C.c_int64()
            rc = d.ceyx_probe_output_size_format(p, 0, YUV420, C.byref(w), C.byref(h), C.byref(b))
            P("PROBE", name, "rc=%d %dx%d bytes=%d" % (rc, w.value, h.value, b.value))
            if rc != 0:
                raise GateError("probe failed rc=%d for %s" % (rc, name))
            files.append((name, p, b.value))

        samples = {"pre_decode": take_sample("pre_decode", t0, cross_check=True)}
        P("SAMPLE", json.dumps(samples["pre_decode"]))

        work = files * a.passes
        random.Random(a.seed).shuffle(work)
        P("ORDER", " ".join(n for n, _, _ in work))
        lock = threading.Lock()
        per_decode, errors, spans = [], [], []

        def lane(i):
            for name, p, nbytes in work[i::a.threads]:
                buf = C.create_string_buffer(nbytes)
                ts = time.perf_counter()
                r = d.ceyx_decode_into_buffer_format(p, 0, buf, nbytes, YUV420, None)
                te = time.perf_counter()
                rr = r.contents
                with lock:
                    spans.append((ts, te))
                    s = take_sample("dec", t0)
                    per_decode.append(s)
                    if rr.error_code != 0:
                        errors.append((name, rr.error_code))
                    P("DEC lane=%d %s rc=%d %dx%d wall_ms=%.0f tc=%.1f pb=%.1f wc=%.1f regions=%s"
                      % (i, name, rr.error_code, rr.width, rr.height, (te - ts) * 1000,
                         s["tc_mib"], s["pb_mib"], s["wc_total_mib"], s["wc_regions_mib"]))
                d.dng_free_result(r)
                del buf
        threads = [threading.Thread(target=lane, args=(i,)) for i in range(a.threads)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        ev = sorted([(x, 1) for x, _ in spans] + [(y, -1) for _, y in spans])
        cur = mx = 0
        for _, s in ev:
            cur += s
            mx = max(mx, cur)
        P("MAX_CONCURRENT_DECODES", mx, "decodes", len(spans), "errors", errors)

        samples["after_decode"] = take_sample("after_decode", t0, cross_check=True)
        P("SAMPLE", json.dumps(samples["after_decode"]))
        ts = time.perf_counter()
        shrunk = d.ceyx_native_idle_shrink(a.floor)
        shrink_ms = (time.perf_counter() - ts) * 1000
        P("IDLE_SHRINK floor=%d returned=%d ms=%.1f at=%s" % (a.floor, shrunk, shrink_ms, now()))
        time.sleep(a.idle_wait)
        samples["idle"] = take_sample("idle", t0, cross_check=True)
        P("SAMPLE", json.dumps(samples["idle"]))
        peak = {"name": "peak"}
        for k in ("tc_mib", "pb_mib", "wc_total_mib"):
            peak[k] = max([s[k] for s in per_decode] + [samples["after_decode"][k]])
        peak["wc_regions_mib"] = max([s["wc_regions_mib"] for s in per_decode] + [samples["after_decode"]["wc_regions_mib"]],
                                     key=lambda r: sum(r))
        samples["peak"] = peak
        stdio.flush()

        # 3-4. samples and judged values
        res.w("## 3. Samples", "",
              "per-decode samples: %d (native.log DEC lines); max concurrent decodes: %d; decode errors: %d"
              % (len(per_decode), mx, len(errors)),
              "idle_shrink(%d) returned %d bytes in %.1f ms; idle sample taken %.1f s later"
              % (a.floor, shrunk, shrink_ms, samples["idle"]["t_s"] - samples["after_decode"]["t_s"]), "")
        res.w("| sample | t_s | TotalCommitted_MiB (PDH) | TotalCommitted_MiB (Get-Counter) | PrivateBytes_MiB | WC_total_MiB | WC regions >=16 MiB |",
              "|---|---|---|---|---|---|---|")
        for k in SAMPLES:
            s = samples[k]
            res.w("| %s | %s | %.1f | %s | %.1f | %.1f | %s |" % (
                k, s.get("t_s", "max-over-decodes"), s["tc_mib"],
                "%s (rc=%s)" % (s["tc_mib_getcounter"], s["getcounter_rc"]) if "tc_mib_getcounter" in s else "-",
                s["pb_mib"], s["wc_total_mib"], s["wc_regions_mib"]))
        res.w("", "peak = per-metric maximum over every post-decode sample (each metric maximised independently;"
              " the peak region list is the sample with the largest WC region sum).", "")
        values = {}
        for k in SAMPLES:
            for m, v in derive(samples[k]).items():
                values["%s.%s" % (k, m)] = v
        for k in SAMPLES:
            values["%s.decode_errors" % k] = float(len(errors))
            values["%s.decodes" % k] = float(len(spans))
        res.w("## 4. Judged values (after_decode / idle)", "")
        for k in ("after_decode", "idle"):
            for m in METRICS[:6]:
                res.w("%s.%s = %s" % (k, m, values["%s.%s" % (k, m)]))
        res.w("")
        with open(os.path.join(a.out, "values.json"), "w", encoding="utf-8") as f:
            json.dump({"label": a.label, "values": values, "samples": samples}, f, indent=1)

        # 5-6. funnel counters + stderr markers
        res.w("## 5. Funnel counters", "",
              "ceyx_debug_idle_funnel_counters: %s" % ("present (ABI reader lands with M1)" if has_funnel_counters else "absent"), "")
        err_txt = open(os.path.join(a.out, "native_stderr.log"), encoding="utf-8", errors="replace").read()
        funnel = [ln for ln in err_txt.splitlines() if "[IdleFunnel]" in ln]
        res.w("## 6. [IdleFunnel] stderr lines", "", *(funnel or ["NONE"]),
              "", "native_stderr.log bytes: %d" % len(err_txt.encode("utf-8", "replace")), "")

        # 7. verdict
        lines, rc_total = judge(expects, reports, values)
        if errors:
            lines.insert(0, "DECODE_ERRORS %s (a gate on fewer decodes is a different gate)" % errors)
            rc_total = 1
            lines[-1] = "MEMGATE_RC=1"
        res.w("## 7. Verdict and RC", "", *lines)
        res.w("RC=%d" % rc_total, "finished %s" % now())
    except Exception as e:
        rc_total = 2
        res.w("", "## ERROR", "", "```", traceback.format_exc().rstrip(), "```", "MEMGATE_RC=2", "RC=2",
              "finished %s" % now())
        P("ERROR", repr(e))
    return rc_total


# --------------------------------------------------------------------------
# compare
# --------------------------------------------------------------------------

def cmd_compare(a):
    text, digest, expects, reports = read_prereg(a.prereg)
    values = {}
    for side, path in (("base", a.base), ("cand", a.cand)):
        vj = json.load(open(os.path.join(path, "values.json"), encoding="utf-8"))
        for k, v in vj["values"].items():
            values["%s.%s" % (side, k)] = v
    lines, rc = judge(expects, reports, values)
    out = ["# D5 compare", "", "base: %s" % os.path.abspath(a.base), "cand: %s" % os.path.abspath(a.cand), "",
           "## Pre-registration (verbatim)", "", "file: %s" % os.path.abspath(a.prereg), "sha256: %s" % digest,
           "", "```", text.rstrip("\n"), "```", "", "## Verdict", ""] + lines + ["RC=%d" % rc, "finished %s" % now()]
    if a.out:
        with open(a.out, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(out) + "\n")
    if sys.stdout is not None:
        print("\n".join(lines))
    return rc


# --------------------------------------------------------------------------
# detach / supervise
# --------------------------------------------------------------------------

def cmd_detach(a):
    os.makedirs(a.out, exist_ok=True)
    argv = [sys.executable, os.path.abspath(__file__), "supervise", "--out", a.out, "--"] + a.rest
    flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB
    p = subprocess.Popen(argv, creationflags=flags, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    with open(os.path.join(a.out, "supervisor.txt"), "a", encoding="utf-8") as f:
        f.write("detached supervisor pid=%d at %s argv=%s\n" % (p.pid, now(), argv))
    return 0


def cmd_supervise(a):
    sup = open(os.path.join(a.out, "supervisor.txt"), "a", encoding="utf-8", buffering=1)
    argv = [sys.executable, os.path.abspath(__file__)] + a.rest
    p = subprocess.Popen(argv, creationflags=CREATE_NO_WINDOW, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sup.write("child pid=%d started %s\n" % (p.pid, now()))
    rc = p.wait()
    sup.write("child pid=%d exited %s PROCESS_RC=%d\n" % (p.pid, now(), rc))
    with open(os.path.join(a.out, "result.md"), "a", encoding="utf-8", newline="\n") as f:
        f.write("PROCESS_RC=%d (child pid %d, captured by supervisor at %s)\n" % (rc, p.pid, now()))
    return 0


def build_parser():
    ap = argparse.ArgumentParser(prog="memgate.py")
    sp = ap.add_subparsers(dest="cmd", required=True)
    m = sp.add_parser("manifest")
    m.add_argument("--corpus", required=True)
    m.add_argument("--out", required=True)
    n = sp.add_parser("native")
    n.add_argument("--dll-dir", required=True)
    n.add_argument("--prereg", required=True)
    n.add_argument("--out", required=True)
    n.add_argument("--label", required=True)
    n.add_argument("--threads", type=int, default=2)
    n.add_argument("--passes", type=int, default=2)
    n.add_argument("--seed", type=int, default=20261003)
    n.add_argument("--floor", type=int, default=2)
    n.add_argument("--idle-wait", type=float, default=12.0)
    n.add_argument("--manifest", default=MANIFEST_PATH)
    n.add_argument("--corpus", default=None)
    n.add_argument("--pin-ref", default=None, help="git ref whose scripts/ceyx_release_pin.json the DLLs must equal")
    n.add_argument("--ceyx-repo", default=os.path.join(os.path.dirname(HALCYON_ROOT), "ceyx"))
    c = sp.add_parser("compare")
    c.add_argument("--base", required=True)
    c.add_argument("--cand", required=True)
    c.add_argument("--prereg", required=True)
    c.add_argument("--out", default=None)
    for name in ("detach", "supervise"):
        x = sp.add_parser(name)
        x.add_argument("--out", required=True)
        x.add_argument("rest", nargs=argparse.REMAINDER)
    return ap


def main(argv=None):
    a = build_parser().parse_args(argv)
    if getattr(a, "rest", None) and a.rest[0] == "--":
        a.rest = a.rest[1:]
    return {"manifest": cmd_manifest, "native": cmd_native, "compare": cmd_compare,
            "detach": cmd_detach, "supervise": cmd_supervise}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
