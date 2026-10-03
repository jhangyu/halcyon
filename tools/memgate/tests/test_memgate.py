import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import memgate  # noqa: E402

SCRATCH = os.path.join(memgate.HALCYON_ROOT, "tmp")

PREREG_T1_T2 = """# prereg
## Expected values
- EXPECT T1_tc: base.idle.tc_mib - cand.idle.tc_mib >= 1024
- EXPECT T1_wc: base.idle.wc_total_mib - cand.idle.wc_total_mib >= 1024
- EXPECT T2: cand.idle.wc_count_ge_256 <= 0
- REPORT peak_delta: base.peak.tc_mib - cand.peak.tc_mib
## Notes
- EXPECT IGNORED: base.idle.tc_mib >= 999999
"""


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def values_dir(root, name, idle_tc, idle_wc, idle_256, peak_tc=2000.0):
    d = os.path.join(root, name)
    os.makedirs(d)
    v = {"idle.tc_mib": idle_tc, "idle.wc_total_mib": idle_wc, "idle.wc_count_ge_256": idle_256,
         "peak.tc_mib": peak_tc}
    write(os.path.join(d, "values.json"), json.dumps({"label": name, "values": v}))
    return d


class Prereg(unittest.TestCase):
    def setUp(self):
        os.makedirs(SCRATCH, exist_ok=True)
        self.t = tempfile.TemporaryDirectory(dir=SCRATCH)
        self.root = self.t.name

    def tearDown(self):
        self.t.cleanup()

    def test_missing_prereg_refused(self):
        with self.assertRaisesRegex(memgate.GateError, "REFUSED"):
            memgate.read_prereg(os.path.join(self.root, "nope.md"))

    def test_prereg_without_section_refused(self):
        p = os.path.join(self.root, "p.md")
        write(p, "# x\n- EXPECT A: idle.tc_mib >= 1\n")
        with self.assertRaisesRegex(memgate.GateError, "Expected values"):
            memgate.read_prereg(p)

    def test_prereg_with_no_expect_refused(self):
        p = os.path.join(self.root, "p.md")
        write(p, "# x\n## Expected values\n- REPORT A: idle.tc_mib\n")
        with self.assertRaisesRegex(memgate.GateError, "vacuously"):
            memgate.read_prereg(p)

    def test_expect_lines_outside_section_ignored(self):
        p = os.path.join(self.root, "p.md")
        write(p, PREREG_T1_T2)
        _, _, expects, reports = memgate.read_prereg(p)
        self.assertEqual([e[0] for e in expects], ["T1_tc", "T1_wc", "T2"])
        self.assertEqual([r[0] for r in reports], ["peak_delta"])

    def test_native_refuses_without_prereg(self):
        out = os.path.join(self.root, "run")
        rc = memgate.main(["native", "--dll-dir", self.root, "--prereg", os.path.join(self.root, "nope.md"),
                           "--out", out, "--label", "x"])
        self.assertEqual(rc, 2)
        txt = open(os.path.join(out, "result.md"), encoding="utf-8").read()
        self.assertIn("REFUSED", txt)
        self.assertNotIn("## 3. Samples", txt)


class Corpus(unittest.TestCase):
    def setUp(self):
        os.makedirs(SCRATCH, exist_ok=True)
        self.t = tempfile.TemporaryDirectory(dir=SCRATCH)
        self.root = self.t.name
        self.corpus = os.path.join(self.root, "corpus")
        os.makedirs(self.corpus)
        write(os.path.join(self.corpus, "a.raw"), "aaaa")
        self.manifest = os.path.join(self.root, "m.json")
        write(self.manifest, json.dumps({"files": {"a.raw": memgate.sha256_file(os.path.join(self.corpus, "a.raw"))}}))

    def tearDown(self):
        self.t.cleanup()

    def test_manifest_ok(self):
        self.assertEqual(memgate.verify_corpus(json.load(open(self.manifest)), self.corpus), [])

    def test_manifest_mismatch_fails_run(self):
        write(os.path.join(self.corpus, "a.raw"), "tampered")
        m = json.load(open(self.manifest))
        self.assertEqual(memgate.verify_corpus(m, self.corpus), ["sha256 mismatch a.raw"])
        prereg = os.path.join(self.root, "p.md")
        write(prereg, "## Expected values\n- EXPECT A: idle.tc_mib >= 0\n")
        out = os.path.join(self.root, "run")
        rc = memgate.main(["native", "--dll-dir", self.root, "--prereg", prereg, "--out", out, "--label", "x",
                           "--manifest", self.manifest, "--corpus", self.corpus])
        self.assertEqual(rc, 2)
        txt = open(os.path.join(out, "result.md"), encoding="utf-8").read()
        self.assertIn("corpus_check: FAIL sha256 mismatch a.raw", txt)
        self.assertIn("MEMGATE_RC=2", txt)

    def test_manifest_missing_file(self):
        os.remove(os.path.join(self.corpus, "a.raw"))
        self.assertEqual(memgate.verify_corpus(json.load(open(self.manifest)), self.corpus), ["missing a.raw"])


class UserStore(unittest.TestCase):
    def setUp(self):
        os.makedirs(SCRATCH, exist_ok=True)
        self.t = tempfile.TemporaryDirectory(dir=SCRATCH)
        self.store = os.path.join(self.t.name, "jhangy.us", "Halcyon")

    def tearDown(self):
        self.t.cleanup()

    def test_untouched_store_is_clean(self):
        os.makedirs(self.store)
        before = memgate.store_snapshot(self.store)
        self.assertEqual(memgate.store_diff(before, memgate.store_snapshot(self.store)), [])

    def test_created_prefs_file_is_detected(self):
        os.makedirs(self.store)
        before = memgate.store_snapshot(self.store)
        write(os.path.join(self.store, "shared_preferences.json"), "{}")
        self.assertEqual(memgate.store_diff(before, memgate.store_snapshot(self.store)),
                         ["added shared_preferences.json"])

    def test_modified_and_created_dir_detected(self):
        before = memgate.store_snapshot(self.store)
        os.makedirs(self.store)
        self.assertEqual(memgate.store_diff(before, memgate.store_snapshot(self.store)),
                         ["directory exists False -> True"])
        write(os.path.join(self.store, "a"), "1")
        b2 = memgate.store_snapshot(self.store)
        write(os.path.join(self.store, "a"), "2")
        self.assertEqual(memgate.store_diff(b2, memgate.store_snapshot(self.store)), ["modified a"])


class Compare(unittest.TestCase):
    def setUp(self):
        os.makedirs(SCRATCH, exist_ok=True)
        self.t = tempfile.TemporaryDirectory(dir=SCRATCH)
        self.root = self.t.name
        self.prereg = os.path.join(self.root, "p.md")
        write(self.prereg, PREREG_T1_T2)
        self.base = values_dir(self.root, "base", idle_tc=1800.0, idle_wc=1850.0, idle_256=3)

    def tearDown(self):
        self.t.cleanup()

    def run_compare(self, cand):
        out = os.path.join(self.root, "cmp.md")
        rc = memgate.main(["compare", "--base", self.base, "--cand", cand, "--prereg", self.prereg, "--out", out])
        return rc, open(out, encoding="utf-8").read()

    def test_t1_t2_pass(self):
        cand = values_dir(self.root, "good", idle_tc=300.0, idle_wc=310.0, idle_256=0)
        rc, txt = self.run_compare(cand)
        self.assertEqual(rc, 0)
        self.assertIn("MEMGATE_TARGET T1_tc value=1500.0 threshold=>=1024 verdict=PASS", txt)
        self.assertIn("MEMGATE_TARGET T2 value=0.0 threshold=<=0 verdict=PASS", txt)
        self.assertIn("verdict=REPORT", txt)
        self.assertIn("MEMGATE_RC=0", txt)

    def test_t1_t2_fail_on_unpatched(self):
        cand = values_dir(self.root, "same", idle_tc=1790.0, idle_wc=1850.0, idle_256=3)
        rc, txt = self.run_compare(cand)
        self.assertEqual(rc, 1)
        self.assertIn("MEMGATE_TARGET T1_tc value=10.0 threshold=>=1024 verdict=FAIL", txt)
        self.assertIn("MEMGATE_TARGET T2 value=3.0 threshold=<=0 verdict=FAIL", txt)
        self.assertIn("MEMGATE_RC=1", txt)

    def test_one_failing_target_fails_gate(self):
        cand = values_dir(self.root, "half", idle_tc=300.0, idle_wc=1800.0, idle_256=0)
        rc, txt = self.run_compare(cand)
        self.assertEqual(rc, 1)
        self.assertIn("T1_wc value=50.0 threshold=>=1024 verdict=FAIL", txt)

    def test_absent_metric_is_fail_not_pass(self):
        d = os.path.join(self.root, "partial")
        os.makedirs(d)
        write(os.path.join(d, "values.json"), json.dumps({"values": {"idle.tc_mib": 1.0}}))
        rc, txt = self.run_compare(d)
        self.assertEqual(rc, 1)
        self.assertIn("value=ERROR", txt)


class Expr(unittest.TestCase):
    def test_arithmetic(self):
        v = {"a.idle.tc_mib": 100.0, "b.idle.tc_mib": 90.0}
        self.assertAlmostEqual(memgate.eval_expr("a.idle.tc_mib - 1.1*b.idle.tc_mib", v), 1.0)
        self.assertAlmostEqual(memgate.eval_expr("-a.idle.tc_mib / 4", v), -25.0)

    def test_disallowed(self):
        for bad in ("__import__('os')", "a.idle.tc_mib if 1 else 2", "abs(a.idle.tc_mib)"):
            with self.assertRaises(memgate.GateError):
                memgate.eval_expr(bad, {"a.idle.tc_mib": 1.0})

    def test_derive_counts_regions(self):
        s = {"tc_mib": 1.0, "pb_mib": 2.0, "wc_total_mib": 900.0, "wc_regions_mib": [346.2, 256.0, 255.9, 16.0]}
        d = memgate.derive(s)
        self.assertEqual(d["wc_count_ge_256"], 2)
        self.assertEqual(d["wc_count_ge_16"], 4)
        self.assertEqual(d["wc_max_region_mib"], 346.2)


class Probes(unittest.TestCase):
    """The live readers must run in-process without error (values are not judged here)."""

    def test_readers(self):
        tc, n, _ = memgate.gpu_total_committed(os.getpid())
        self.assertGreaterEqual(tc, 0.0)
        self.assertGreater(memgate.private_bytes_mib(), 0.0)
        tot, regions = memgate.wc_walk()
        self.assertGreaterEqual(tot, 0.0)

    def test_wc_detail_records_address_and_ownership(self):
        import ctypes as C
        k32 = C.windll.kernel32
        k32.VirtualAlloc.restype = C.c_void_p
        k32.VirtualAlloc.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.c_uint32]
        k32.VirtualFree.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32]
        size = 2 << 20
        p = k32.VirtualAlloc(None, size, 0x3000, 0x404)  # MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE|PAGE_WRITECOMBINE
        self.assertTrue(p)
        try:
            got = [r for r in memgate.wc_detail(min_bytes=1 << 20) if r["base"] == hex(p)]
            self.assertEqual(len(got), 1)
            r = got[0]
            self.assertEqual((r["abase"], r["bytes"], r["protect"], r["state"], r["type"]),
                             (hex(p), size, "0x404", "0x1000", "0x20000"))
            self.assertFalse([x for x in memgate.wc_detail(min_bytes=4 << 20) if x["base"] == hex(p)])
        finally:
            k32.VirtualFree(p, 0, 0x8000)

    def test_gpu_release_registered_at_exit(self):
        calls, registered = [], []

        class FakeDll:
            def ceyx_native_release_gpu(self):
                calls.append(1)
        orig = memgate.atexit.register
        memgate.atexit.register = registered.append
        try:
            memgate.release_gpu_at_exit(FakeDll())
        finally:
            memgate.atexit.register = orig
        self.assertEqual(len(registered), 1)
        registered[0]()
        self.assertEqual(calls, [1])

    def test_pe_exports_reads_python_dll(self):
        dll = os.path.join(os.path.dirname(sys.executable), "python3.dll")
        self.assertIn("Py_Initialize", memgate.pe_exports(dll))


class FunnelCounters(unittest.TestCase):
    """E1: the IC1 ABI reader (7 uint64 outs in plan order, int32 return)."""

    @staticmethod
    def fake(values, rc=0):
        def fn(*ptrs):
            assert len(ptrs) == 7
            for p, v in zip(ptrs, values):
                p.contents.value = v
            return rc
        return fn

    def test_reads_seven_counters_in_abi_order(self):
        got = memgate.read_funnel_counters(self.fake([5, 4, 1, 0, 0, 0, 123456789]))
        self.assertEqual(list(got), list(memgate.FUNNEL_FIELDS))
        self.assertEqual(got["funnel_calls"], 5)
        self.assertEqual(got["device_release_runs"], 4)
        self.assertEqual(got["device_release_skipped_uninitialized"], 1)
        self.assertEqual(got["last_funnel_bytes"], 123456789)

    def test_nonzero_return_is_an_error(self):
        with self.assertRaisesRegex(memgate.GateError, "returned -1"):
            memgate.read_funnel_counters(self.fake([0] * 7, rc=-1))

    def test_released_lines_counted_exactly(self):
        err = ("noise\n"
               "[IdleFunnel] event=funnel floor=2 arena_bytes=1 dng_bytes=0 device_release=released\n"
               "[IdleFunnel] event=funnel floor=2 arena_bytes=0 dng_bytes=0 device_release=skipped_uninitialized\n"
               "x [IdleFunnel] event=funnel floor=2 arena_bytes=0 dng_bytes=0 device_release=released\n")
        self.assertEqual(memgate.idlefunnel_released_lines(err), 2)


class DecodeCount(unittest.TestCase):
    """Parked S3: a run with fewer decodes than the procedure demands is not the gate."""

    def test_exact_count_ok(self):
        self.assertIsNone(memgate.decode_count_problem(26, 13, 2))

    def test_short_count_flagged(self):
        self.assertIn("actual=25 expected=26", memgate.decode_count_problem(25, 13, 2))


class AllocationVerdict(unittest.TestCase):
    """Amended T3 (contract :50): allocation-level, GPU-context heap excluded only when proven."""

    MIB = 1 << 20
    ARENA = {"base": hex(0x10000000), "bytes": 256 * (1 << 20)}

    def sample(self, wc_total, allocs, arenas=None):
        return {"wc_total_mib": wc_total,
                "wc_detail": [{"base": a, "abase": a, "bytes": int(mib * self.MIB), "protect": "0x404",
                               "alloc_protect": "0x4", "state": "0x1000", "type": "0x20000"}
                              for a, mib in allocs],
                "arena_ranges": [self.ARENA] if arenas is None else arenas}

    def test_steady_heap_excluded_and_net_residue(self):
        pre = self.sample(0.0, [])
        i1 = self.sample(17.2, [(hex(0x50000000), 16.0)])
        i2 = self.sample(17.2, [(hex(0x50000000), 16.0)])
        v = memgate.alloc_verdict_values(pre, i1, i2)
        self.assertEqual((v["alloc.ceyx_held_ge16"], v["alloc.ctx_heap_unproven"]), (0.0, 0.0))
        self.assertEqual(v["alloc.ctx_heap_mib"], 16.0)
        self.assertAlmostEqual(v["alloc.net_residue_mib"], 1.2)

    def test_growth_between_idles_is_unproven(self):
        pre = self.sample(0.0, [])
        i1 = self.sample(17.2, [(hex(0x50000000), 16.0)])
        i2 = self.sample(17.5, [(hex(0x50000000), 16.25)])
        v = memgate.alloc_verdict_values(pre, i1, i2)
        self.assertEqual(v["alloc.ctx_heap_unproven"], 1.0)
        self.assertEqual(v["alloc.ctx_heap_mib"], 0.0)

    def test_new_at_second_idle_is_unproven(self):
        v = memgate.alloc_verdict_values(self.sample(0.0, []), self.sample(0.0, []),
                                         self.sample(20.0, [(hex(0x50000000), 20.0)]))
        self.assertEqual(v["alloc.ctx_heap_unproven"], 1.0)

    def test_ceyx_held_allocation_counted(self):
        a = hex(0x10000000 + 4096)
        i = self.sample(32.0, [(a, 32.0)])
        v = memgate.alloc_verdict_values(self.sample(0.0, []), i, i)
        self.assertEqual(v["alloc.ceyx_held_ge16"], 1.0)
        self.assertEqual(v["alloc.ctx_heap_mib"], 0.0)

    def test_split_regions_summed_per_allocation(self):
        i = self.sample(20.0, [])
        i["wc_detail"] = [{"base": hex(0x50000000 + k * 0x1000000), "abase": hex(0x50000000),
                           "bytes": 10 * self.MIB} for k in range(2)]
        v = memgate.alloc_verdict_values(self.sample(0.0, []), i, i)
        self.assertEqual(v["alloc.ctx_heap_mib"], 20.0)

    def test_judge_growth_fails_steady_passes(self):
        expects = [("T3.held", "alloc.ceyx_held_ge16", "<=", 0.0),
                   ("T3.heap", "alloc.ctx_heap_unproven", "<=", 0.0),
                   ("T3.net", "alloc.net_residue_mib", "<=", 16.0)]
        pre = self.sample(0.0, [])
        ok = memgate.alloc_verdict_values(pre, self.sample(17.0, [(hex(0x50000000), 16.0)]),
                                          self.sample(17.0, [(hex(0x50000000), 16.0)]))
        self.assertEqual(memgate.judge(expects, [], ok)[1], 0)
        bad = memgate.alloc_verdict_values(pre, self.sample(17.0, [(hex(0x50000000), 16.0)]),
                                           self.sample(18.0, [(hex(0x50000000), 17.0)]))
        lines, rc = memgate.judge(expects, [], bad)
        self.assertEqual(rc, 1)
        self.assertTrue(any("T3.heap" in ln and "verdict=FAIL" in ln for ln in lines))

    def test_wc_alloc_sums_groups_and_orders(self):
        d = [{"abase": "0xa", "bytes": 3 * self.MIB}, {"abase": "0xb", "bytes": 8 * self.MIB},
             {"abase": "0xa", "bytes": 2 * self.MIB}]
        got = memgate.wc_alloc_sums(d)
        self.assertEqual(got, {"0xb": 8.0, "0xa": 5.0})
        self.assertEqual(list(got), ["0xb", "0xa"])

    def test_empty_arena_ranges_is_error(self):
        s = self.sample(0.0, [(hex(0x50000000), 16.0)], arenas=[])
        with self.assertRaises(memgate.GateError):
            memgate.alloc_verdict_values(s, s, s)

    def test_missing_arena_ranges_is_error(self):
        s = self.sample(0.0, [])
        del s["arena_ranges"]
        with self.assertRaises(memgate.GateError):
            memgate.alloc_verdict_values(s, s, s)


PERF_LOG = "\n".join([
    "PERF|1000000|driver.config|dir=x|n=26|pace=6000|mode=memgate|iso=main",
    "PERF|2000000|memgate.walk.begin|n=26|pace=6000|iso=main",
    "PERF|2000100|memgate.step|t_ms=2000|step=0|id=a|iso=main",
    "PERF|2500000|req_end|id=a|dur=1|rawDecode=true|payloadKind=Pixel|bytes=1|cost=x|exifOrientation=null|rotatedPass=false|iso=main",
    "PERF|2600000|materialize|id=77|bytes=400|dur_us=5|src=fullres|iso=main",
    "PERF|3000000|memgate|t_ms=3000|phase=walk|step=0|live_image_bytes=100|cache_bytes=0|cache_count=0|lane_width=2|funnel_calls=0|device_release_runs=0|displayed_redecodes=absent|iso=main",
    "PERF|8000100|memgate.step|t_ms=8000|step=1|id=b|iso=main",
    "PERF|8100000|req_end|id=b|dur=1|rawDecode=true|payloadKind=Pixel|bytes=1|cost=x|exifOrientation=null|rotatedPass=false|iso=main",
    "PERF|8200000|req_end|id=c|dur=1|rawDecode=false|payloadKind=Encoded|bytes=1|cost=x|exifOrientation=null|rotatedPass=false|iso=main",
    "PERF|8300000|normalize_end|ok=true|dur=5|w=10|h=20|iso=main",
    "PERF|9000000|memgate|t_ms=9000|phase=walk|step=1|live_image_bytes=100|cache_bytes=0|cache_count=0|lane_width=5|funnel_calls=1|device_release_runs=1|displayed_redecodes=absent|iso=main",
    "PERF|20000000|memgate|t_ms=20000|phase=idle|step=2|live_image_bytes=4000|cache_bytes=0|cache_count=0|lane_width=2|funnel_calls=3|device_release_runs=2|displayed_redecodes=absent|iso=main",
    "PERF|21000000|memgate|done|t_ms=21000|iso=main",
])


class AppLog(unittest.TestCase):
    """E2: the PerfDriver memgate-mode log contract (IC8)."""

    def test_parse_samples_steps_done(self):
        p = memgate.parse_perf_log(PERF_LOG)
        self.assertEqual(len(p["samples"]), 3)
        self.assertEqual([s["phase"] for s in p["samples"]], ["walk", "walk", "idle"])
        self.assertEqual([(s["step"], s["id"]) for s in p["steps"]], [(0, "a"), (1, "b")])
        self.assertEqual(p["done_t_ms"], 21000)
        self.assertEqual(p["samples"][2]["device_release_runs"], 2)

    def test_lane_width_violation_counted(self):
        p = memgate.parse_perf_log(PERF_LOG)
        self.assertEqual(memgate.lane_width_violations(p["samples"], 2), 1)

    def test_raw_decodes_attributed_to_step(self):
        p = memgate.parse_perf_log(PERF_LOG)
        self.assertEqual(p["raw_decodes_per_step"], {0: 1, 1: 1})

    def test_full_frame_sizes_collected(self):
        p = memgate.parse_perf_log(PERF_LOG)
        self.assertEqual(sorted(p["frame_bytes"]), [400, 800])

    def test_texture_exclusion(self):
        mib = 1 << 20
        frames = [150 * mib, 230 * mib]
        # 368 MiB = 1.6 x 230 MiB -> texture; 300 MiB matches nothing in [1.5, 1.7] x {150, 230}.
        nontex, tex = memgate.split_texture_regions([368.0, 300.0, 20.0], frames, live_bytes=400 * mib)
        self.assertEqual(nontex, [300.0, 20.0])
        self.assertEqual(tex, [368.0])

    def test_texture_exclusion_void_when_more_than_live(self):
        mib = 1 << 20
        nontex, tex = memgate.split_texture_regions([368.0], [230 * mib], live_bytes=100 * mib)
        self.assertEqual(nontex, [368.0])
        self.assertEqual(tex, [])

    def test_app_refuses_without_prereg_and_never_launches(self):
        os.makedirs(SCRATCH, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            out = os.path.join(root, "run")
            rc = memgate.main(["app", "--exe", os.path.join(root, "halcyon.exe"), "--prereg",
                               os.path.join(root, "nope.md"), "--out", out, "--label", "x"])
            self.assertEqual(rc, 2)
            txt = open(os.path.join(out, "result.md"), encoding="utf-8").read()
            self.assertIn("REFUSED", txt)
            self.assertNotIn("launched pid", txt)


class SelfHash(unittest.TestCase):
    """Parked S4: every artifact records the sha256 of the memgate.py that produced it."""

    def test_native_result_records_tool_hash(self):
        os.makedirs(SCRATCH, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            out = os.path.join(root, "run")
            memgate.main(["native", "--dll-dir", root, "--prereg", os.path.join(root, "nope.md"),
                          "--out", out, "--label", "x"])
            txt = open(os.path.join(out, "result.md"), encoding="utf-8").read()
            self.assertIn("memgate_py_sha256: %s" % memgate.sha256_file(memgate.__file__), txt)

    def test_compare_records_tool_hash(self):
        os.makedirs(SCRATCH, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=SCRATCH) as root:
            prereg = os.path.join(root, "p.md")
            write(prereg, PREREG_T1_T2)
            base = values_dir(root, "b", 1.0, 1.0, 0)
            out = os.path.join(root, "cmp.md")
            memgate.main(["compare", "--base", base, "--cand", base, "--prereg", prereg, "--out", out])
            self.assertIn("memgate_py_sha256: %s" % memgate.sha256_file(memgate.__file__),
                          open(out, encoding="utf-8").read())


T4_IDS = ["i%02d" % k for k in range(13)]


def t4_log(extra_after=None, extra_before_marker=None, drop=None):
    """Synthetic 26-step wrap walk, one publish per band entrant (preflight 1.2).
    The jump's publish of i00 is synchronous: it lands BEFORE the step-13 marker.
    extra_after[step] / extra_before_marker[step] add raw lines; drop = set of
    (step) whose entrant publish is omitted."""
    extra_after, extra_before_marker, drop = extra_after or {}, extra_before_marker or {}, drop or set()
    us = [1000]
    out = []

    def add(msg):
        us[0] += 10
        out.append("PERF|%d|%s|iso=main" % (us[0], msg))

    add("memgate.walk.begin|n=26|pace=6000")
    for step in range(26):
        tid = T4_IDS[step % 13]
        if step == 0:
            for e in (0, 1):
                add("publish|id=%s|path=publishEncoded" % T4_IDS[e])
        for ln in extra_before_marker.get(step, []):
            add(ln)
        if step == 13:
            add("publish|id=%s|path=publishEncoded" % T4_IDS[0])
        add("memgate.step|t_ms=%d|step=%d|id=%s" % (step * 6000, step, tid))
        if step > 0 and step not in (12, 13, 25) and step not in drop:
            add("publish|id=%s|path=%s" % (T4_IDS[(step + 1) % 13], "upgrade" if step == 7 else "publishEncoded"))
        if step == 13:
            add("publish|id=%s|path=publishEncoded" % T4_IDS[1])
        for ln in extra_after.get(step, []):
            add(ln)
    add("memgate.walk.end|steps=26")
    add("memgate|done|t_ms=1")
    return "\n".join(out) + "\n"


class T4Counter(unittest.TestCase):
    """M2 instrument: T4 tier-2 publish counter over W2 = [step-12 marker, walk.end)."""

    def test_clean_pass_counts_one_per_id(self):
        t = memgate.t4_analysis(t4_log())
        self.assertEqual(t["w2"], {i: 1 for i in T4_IDS})
        self.assertEqual(t["total"], 13)
        self.assertTrue(t["per_id_pass"])
        self.assertTrue(t["valid"])

    def test_excess_publish_in_w2_fails_per_id(self):
        extra = {20: ["publish|id=i05|path=publishEncoded"]}
        t = memgate.t4_analysis(t4_log(extra_after=extra))
        self.assertEqual(t["w2"]["i05"], 2)
        self.assertEqual(t["total"], 14)
        self.assertFalse(t["per_id_pass"])
        self.assertTrue(t["valid"])
        self.assertIn("MEMGATE_TARGET T4.per_id FAIL", "\n".join(memgate.t4_verdict_lines(t)))

    def test_jump_pre_marker_publish_counted_once(self):
        t = memgate.t4_analysis(t4_log())
        self.assertEqual(t["w2"]["i00"], 1)
        self.assertEqual(t["first_pass"]["i00"], 1)
        self.assertTrue(t["per_id_pass"])

    def test_missing_publish_fails_per_id(self):
        t = memgate.t4_analysis(t4_log(drop={20}))
        self.assertEqual(t["w2"]["i08"], 0)
        self.assertFalse(t["per_id_pass"])

    def test_dup_dropped_and_cache_refused_excluded(self):
        extra = {15: ["publish|id=i03|path=publishEncoded|dup_dropped=1",
                      "publish|id=i04|path=upgrade|cache_refused=1"]}
        t = memgate.t4_analysis(t4_log(extra_after=extra))
        self.assertEqual(t["w2"], {i: 1 for i in T4_IDS})
        self.assertTrue(t["per_id_pass"])
        self.assertEqual(t["dup_dropped"], 1)
        self.assertEqual(t["cache_refused"], 1)

    def test_tier1_publish_not_counted(self):
        t = memgate.t4_analysis(t4_log(extra_after={15: ["publish|id=i03|path=tier1"]}))
        self.assertEqual(t["total"], 13)

    def test_raw_decode_in_w2_is_invalid(self):
        extra = {18: ["req_end|id=i05|dur=1|rawDecode=true|payloadKind=Pixel|bytes=1|cost=x|exifOrientation=null|rotatedPass=false"]}
        t = memgate.t4_analysis(t4_log(extra_after=extra))
        self.assertFalse(t["valid"])
        self.assertIn("T4.valid INVALID", "\n".join(memgate.t4_verdict_lines(t)))

    def test_reencode_submit_in_w2_is_invalid(self):
        t = memgate.t4_analysis(t4_log(extra_after={18: ["reencode.submit|id=9|bytes=4"]}))
        self.assertFalse(t["valid"])

    def test_first_pass_activity_reported_not_gated(self):
        early = {3: ["req_end|id=i03|dur=1|rawDecode=true|payloadKind=Pixel|bytes=1|cost=x|exifOrientation=null|rotatedPass=false",
                     "publish|id=i03|path=publishEncoded"]}
        t = memgate.t4_analysis(t4_log(extra_after=early))
        self.assertTrue(t["valid"])
        self.assertTrue(t["per_id_pass"])
        self.assertEqual(t["first_pass"]["i03"], 2)

    def test_missing_step12_marker_is_invalid(self):
        text = "\n".join(ln for ln in t4_log().splitlines() if "|step=12|" not in ln)
        self.assertFalse(memgate.t4_analysis(text)["valid"])

    def test_wrong_id_count_is_invalid(self):
        text = t4_log().replace("|step=3|id=i03", "|step=3|id=i02").replace("|step=16|id=i03", "|step=16|id=i02")
        self.assertFalse(memgate.t4_analysis(text, expected_ids=13)["valid"])


if __name__ == "__main__":
    unittest.main()
