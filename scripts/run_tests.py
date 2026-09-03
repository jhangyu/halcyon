#!/usr/bin/env python3
"""Halcyon unified test entry point — sharded `flutter test` runner.

WHY THIS EXISTS
---------------
`flutter test` over the whole suite has outgrown the foreground command timeout
(150 s). The fix is NOT a longer timeout — it is sharding: the suite is split
into directory-sized shards, each measured to complete well under the cap, and
each shard is a separate child process with its own artifact and its own
self-captured exit code.

This script deliberately does NOT reimplement anything already in `scripts/ci/`:

  * process execution      -> ci.run.run_logged   (shell=False, RC self-capture,
                              Windows .bat resolution, no `| grep`)
  * artifact + RC trailer  -> ci.report.write_log (last line is exactly `RC=<n>`)
  * skip announcements     -> ci.report.skip_line (2026-08-25: a silent skip
                              produces a green report indistinguishable from a
                              full run)

`scripts/ci.py verify` keeps its own monolithic `flutter test -j 1` step,
because a CI runner has no foreground-timeout problem. This script is the
canonical entry point for humans and agents on a laptop, and it is safe to point
CI at it too (`python3 scripts/run_tests.py`).

USAGE
-----
    python3 scripts/run_tests.py                # every shard, in order
    python3 scripts/run_tests.py --list         # print the shard table, run nothing
    python3 scripts/run_tests.py --shard views  # one shard by name
    python3 scripts/run_tests.py --shard 3      # one shard by 1-based index

Artifacts: build/ci-logs/tests-<shard>.txt, last line `RC=<n>`, written by the
producing process (2026-08-23: a harness notification lies in both directions).

Final line on stdout is exactly:

    TOTAL: <X> passed, <Y> failed, RC=<Z>

RC is non-zero if ANY shard failed. In `--shard` mode the same line is printed
for the single shard, so a one-shard invocation is still machine-checkable.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, os.fspath(REPO_ROOT / "scripts"))

from ci import report, run  # noqa: E402  (path bootstrap must precede import)


# ---------------------------------------------------------------------------
# Shard table — DATA, not logic. Derived from the 2026-09-03 timing measurement
# recorded in docs/logs/2026-09-03/test-suite-audit.md. Every shard's measured
# wall time is stated so a future maintainer can see the headroom against the
# 150 s foreground cap without re-measuring. Re-measure and re-split whenever a
# shard's measured time exceeds SHARD_BUDGET_S.
#
# `paths` are passed verbatim to `flutter test`; a directory means "every
# *_test.dart underneath". Splitting the big image_pipeline directory is done by
# explicit file lists so the split is auditable and stable.
# ---------------------------------------------------------------------------

# The binding constraint measured on 2026-09-03 is the DEFAULT foreground cap of
# 40 s, not the 150 s build allowance: a plain `flutter test` invocation is not
# classified as a build command, so it is capped at 40 s. 30 s leaves headroom for
# the machine being busier than it was when these numbers were taken.
SHARD_BUDGET_S = 30

SHARDS = [
    {
        "name": "unit",
        "paths": ["test/main_test.dart", "test/models", "test/perf", "test/providers"],
    },
    {
        # Measured as one 24-file shard: 34.6 s, green but only 5 s under the
        # 40 s cap. Split for the same reason as views-layout.
        "name": "pipeline-a1",
        "paths": [
            "test/services/image_pipeline/bitmap_container_probe_test.dart",
            "test/services/image_pipeline/cache_budget_test.dart",
            "test/services/image_pipeline/cost_memo_longedge_test.dart",
            "test/services/image_pipeline/dart_image_loader_no_method_channel_test.dart",
            "test/services/image_pipeline/dart_image_loader_test.dart",
            "test/services/image_pipeline/decode_lane_test.dart",
            "test/services/image_pipeline/decoded_rgba_image_provider_test.dart",
            "test/services/image_pipeline/decoded_rgba_shortcircuit_test.dart",
        ],
    },
    {
        # The DNG embedded-JPEG extractor family is the single heaviest cluster
        # in the suite (byte-level fixture parsing); it owns a shard by itself.
        "name": "pipeline-dng",
        "paths": [
            "test/services/image_pipeline/dng_decoder_smoke_test.dart",
            "test/services/image_pipeline/dng_embedded_jpeg_extractor_buffer_copy_semantics_test.dart",
            "test/services/image_pipeline/dng_embedded_jpeg_extractor_endian_test.dart",
            "test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart",
            "test/services/image_pipeline/dng_embedded_jpeg_extractor_sony_ifd_chain_test.dart",
            "test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart",
            "test/services/image_pipeline/dng_extractor_transient_read_retry_test.dart",
        ],
    },
    {
        "name": "pipeline-a2",
        "paths": [
            "test/services/image_pipeline/encode_stage_test.dart",
            "test/services/image_pipeline/exif_orientation_test.dart",
            "test/services/image_pipeline/full_decoder_dispatch_sized_fallback_test.dart",
            "test/services/image_pipeline/full_decoder_dispatch_test.dart",
            "test/services/image_pipeline/inflight_bytes_budget_test.dart",
            "test/services/image_pipeline/jpeg_encoder_test.dart",
            "test/services/image_pipeline/payload_normalizer_test.dart",
            "test/services/image_pipeline/payload_reencoder_test.dart",
            "test/services/image_pipeline/photo_payload_cache_test.dart",
        ],
    },
    {
        # Measured 2026-09-03: this half is 22 s and the b2 half is 19 s. Run as
        # one 13-file shard they total 41 s and blow the 40 s foreground cap —
        # which is exactly how this shard was discovered, by timing out.
        "name": "pipeline-b1",
        "paths": [
            "test/services/image_pipeline/image_preload_controller_cheap_on_serial_lane_test.dart",
            "test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart",
            "test/services/image_pipeline/image_preload_controller_lane_race_test.dart",
            "test/services/image_pipeline/image_preload_controller_permanent_miss_test.dart",
            "test/services/image_pipeline/image_preload_controller_probe_first_navigation_test.dart",
            "test/services/image_pipeline/image_preload_controller_sequential_decode_retention_test.dart",
        ],
    },
    {
        "name": "pipeline-b2",
        "paths": [
            "test/services/image_pipeline/image_preload_controller_test.dart",
            "test/services/image_pipeline/image_preload_encode_stage_test.dart",
            "test/services/image_pipeline/image_preload_pacer_test.dart",
            "test/services/image_pipeline/image_preload_reencode_tier_two_test.dart",
            "test/services/image_pipeline/image_preload_reset_tier_one_evict_test.dart",
            "test/services/image_pipeline/image_preload_stage_overlap_test.dart",
            "test/services/image_pipeline/image_preload_window_test.dart",
        ],
    },
    {
        "name": "pipeline-c",
        "paths": [
            "test/services/image_pipeline/photo_source_fullres_handle_test.dart",
            "test/services/image_pipeline/photo_source_probe_test.dart",
            "test/services/image_pipeline/photo_source_reencode_test.dart",
            "test/services/image_pipeline/photo_source_single_probe_test.dart",
            "test/services/image_pipeline/photo_source_test.dart",
            "test/services/image_pipeline/photo_source_two_phase_test.dart",
            "test/services/image_pipeline/preview_floor_longedge_test.dart",
            "test/services/image_pipeline/publication_pacer_test.dart",
            "test/services/image_pipeline/raw_coverage_wiring_test.dart",
            "test/services/image_pipeline/raw_pixels_image_test.dart",
            "test/services/image_pipeline/retention_policy_test.dart",
            "test/services/image_pipeline/retention_tier_test.dart",
            "test/services/image_pipeline/shared_display_quality_test.dart",
            "test/services/image_pipeline/shared_payload_retention_test.dart",
            "test/services/image_pipeline/sidebar_lane_production_test.dart",
            "test/services/image_pipeline/sidebar_pixel_thumbnail_test.dart",
            "test/services/image_pipeline/sidebar_shared_payload_test.dart",
            "test/services/image_pipeline/sidebar_thumbnail_codec_test.dart",
            "test/services/image_pipeline/thumbnail_derivation_test.dart",
            "test/services/image_pipeline/tier_two_piggyback_handle_test.dart",
            "test/services/image_pipeline/tier_two_publish_race_test.dart",
            "test/services/image_pipeline/tier_two_registry_test.dart",
            "test/services/image_pipeline/tier_two_scheduler_test.dart",
        ],
    },
    {
        "name": "services",
        "paths": [
            "test/services/library",
            "test/services/platform",
            "test/services/rename",
        ],
    },
    {
        "name": "views",
        "paths": [
            "test/views/main_screen_shortcuts_test.dart",
            "test/views/rename_dialog_test.dart",
            "test/views/settings_appearance_tab_test.dart",
            "test/views/settings_dialog_test.dart",
            "test/views/status_line_test.dart",
            "test/views/theme_tokens_test.dart",
            "test/views/thumbnail_rebuild_scope_test.dart",
            "test/views/zoom_controller_test.dart",
        ],
    },
    {
        # Split at the gallery/other boundary the file names already provide.
        # Measured as one 30-file shard it was 33.8 s — green, but only 6 s under
        # the 40 s foreground cap, which is not enough margin to survive either a
        # busier machine or the next few test files anyone adds.
        #
        # NOTE these two use explicit file lists rather than a directory glob, so
        # a NEWLY ADDED test/views/layout/ file belongs to neither shard and would
        # silently go unrun. `--audit-coverage` exists to catch exactly that and
        # is asserted by the self-check; do not convert them back to a bare
        # directory path without re-measuring.
        "name": "views-layout-gallery",
        "paths": [
            "test/views/layout/gallery_column_menu_test.dart",
            "test/views/layout/gallery_column_test.dart",
            "test/views/layout/gallery_decode_freeze_test.dart",
            "test/views/layout/gallery_desktop_test.dart",
            "test/views/layout/gallery_flicker_resize_test.dart",
            "test/views/layout/gallery_geometry_test.dart",
            "test/views/layout/gallery_marks_reachability_test.dart",
            "test/views/layout/gallery_marks_test.dart",
            "test/views/layout/gallery_mobile_test.dart",
            "test/views/layout/gallery_open_folder_shortcut_test.dart",
            "test/views/layout/gallery_palette_test.dart",
            "test/views/layout/gallery_thumb_anchor_test.dart",
            "test/views/layout/gallery_thumb_select_test.dart",
        ],
    },
    {
        "name": "views-layout-rest",
        "paths": [
            "test/views/layout/app_actions_menu_test.dart",
            "test/views/layout/darkroom_counter_test.dart",
            "test/views/layout/darkroom_desktop_test.dart",
            "test/views/layout/darkroom_empty_state_test.dart",
            "test/views/layout/darkroom_mobile_test.dart",
            "test/views/layout/exif_caption_joined_test.dart",
            "test/views/layout/exif_caption_test.dart",
            "test/views/layout/filmstrip_anchor_round4_test.dart",
            "test/views/layout/layout_registry_test.dart",
            "test/views/layout/paper_desktop_test.dart",
            "test/views/layout/paper_mobile_test.dart",
            "test/views/layout/paper_mobile_welcome_test.dart",
            "test/views/layout/paper_overcount_test.dart",
            "test/views/layout/paper_palette_test.dart",
            "test/views/layout/paper_welcome_test.dart",
            "test/views/layout/photo_thumbnail_test.dart",
            "test/views/layout/photo_viewport_test.dart",
        ],
    },
]


# ---------------------------------------------------------------------------
# Static declared-test count (the "declared" half of the declared-vs-executed
# check). 2026-08-17: `flutter test`'s progress line is overwritten in place, so
# the only way to know a whole file silently failed to load is to compare the
# count the source declares against the count the run reported.
# ---------------------------------------------------------------------------

_DECL_RE = re.compile(r"^[ \t]*(?:test|testWidgets)\(", re.MULTILINE)


def shard_files(shard):
    """Every *_test.dart a shard's `paths` expand to, sorted and de-duplicated."""
    found = []
    for entry in shard["paths"]:
        target = REPO_ROOT / entry
        if target.is_dir():
            found.extend(sorted(target.rglob("*_test.dart")))
        elif target.is_file():
            found.append(target)
    return sorted(set(found))


def declared_count(files):
    total = 0
    for path in files:
        total += len(_DECL_RE.findall(path.read_text(encoding="utf-8", errors="replace")))
    return total


# `flutter test`'s expanded/compact reporter trailer, e.g.
#   "00:41 +212 -3 ~9: Some test name"
# Skips (`~`) and failures (`-`) are optional. The LAST match in the stream is
# the final tally.
_TALLY_RE = re.compile(r"\+(\d+)(?:\s+-(\d+))?(?:\s+~(\d+))?\s*:")


def parse_tally(text):
    """Returns (passed, failed, skipped) from the last reporter tally, or None."""
    matches = _TALLY_RE.findall(text)
    if not matches:
        return None
    passed, failed, skipped = matches[-1]
    return int(passed), int(failed or 0), int(skipped or 0)


def _loadavg():
    """1/5/15-minute load average, or None where the OS has no such notion."""
    try:
        return os.getloadavg()
    except (OSError, AttributeError):  # pragma: no cover - Windows
        return None


def _fmt_load(load):
    return "unavailable" if load is None else " ".join(f"{v:.2f}" for v in load)


def _append_timing(log_path, elapsed, load_before, load_after):
    """Inserts the timing block immediately BEFORE the artifact's `RC=<n>` line.

    The RC trailer must stay the literal last line (report.write_log's contract,
    so `tail -n 1` prints `RC=<n>` and nothing else) — hence insert, not append.
    """
    path = Path(log_path)
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or not lines[-1].startswith("RC="):
        return
    lines[-1:-1] = [
        f"ELAPSED_SECONDS={elapsed:.1f}",
        f"LOADAVG_BEFORE={_fmt_load(load_before)}",
        f"LOADAVG_AFTER={_fmt_load(load_after)}",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_shard(shard):
    """Runs one shard; returns a result dict. Never raises on a failing child."""
    files = shard_files(shard)
    name = shard["name"]
    if not files:
        print(report.skip_line(f"shard:{name}", "expanded to zero test files"))
        return {"name": name, "rc": 1, "passed": 0, "failed": 0, "skipped": 0,
                "declared": 0, "executed": 0, "log": None}

    declared = declared_count(files)
    log_path = report.log_path_for(REPO_ROOT, "tests", name)
    argv = ["flutter", "test", "-j", "1", *[os.fspath(f.relative_to(REPO_ROOT)) for f in files]]

    # A shard time is only interpretable next to the machine load that produced
    # it: on 2026-09-03 this machine carried a load average near 180 from another
    # session's indexer, which would silently inflate every measurement. Both
    # samples and the elapsed time go INTO the artifact, so the artifact is
    # self-attributing and a future reader never has to trust a remembered number.
    load_before = _loadavg()
    started = time.monotonic()
    result = run.run_logged(argv, log_path, cwd=REPO_ROOT)
    elapsed = time.monotonic() - started
    load_after = _loadavg()
    _append_timing(log_path, elapsed, load_before, load_after)

    tally = parse_tally(result.stdout + result.stderr)
    if tally is None:
        # No tally at all means the run never got as far as reporting — a
        # compile error or a missing toolchain. That is a failure regardless of
        # what the exit code says.
        print(f"SHARD {name}: no reporter tally found in output — treating as failure")
        passed = failed = skipped = 0
        rc = result.returncode or 1
    else:
        passed, failed, skipped = tally
        rc = result.returncode

    executed = passed + failed + skipped
    print(
        f"SHARD {name}: files={len(files)} declared={declared} executed={executed} "
        f"passed={passed} failed={failed} skipped={skipped} "
        f"elapsed={elapsed:.1f}s load={_fmt_load(load_before)} RC={rc} log={log_path}"
    )
    if elapsed > SHARD_BUDGET_S:
        # Not a failure — a re-split signal. Silence here is how a shard drifts
        # over the harness cap and the suite becomes unrunnable again.
        print(
            f"OVER-BUDGET {name}: {elapsed:.1f}s > {SHARD_BUDGET_S}s budget "
            f"(load was {_fmt_load(load_before)}); re-measure on an idle machine "
            "and split this shard if it is genuinely too slow"
        )
    if tally is not None and executed != declared:
        # A warning, not a verdict: `test()` calls emitted inside loops or
        # helper functions legitimately make executed > declared, and a
        # group-level `skip:` can make them differ the other way. It exists so a
        # whole file failing to load can never pass unnoticed.
        print(
            f"COUNT-MISMATCH {name}: declared={declared} executed={executed} "
            "(check the shard log before trusting a green result)"
        )
    return {"name": name, "rc": rc, "passed": passed, "failed": failed,
            "skipped": skipped, "declared": declared, "executed": executed,
            "log": os.fspath(log_path)}


def select_shards(selector):
    if selector is None:
        return SHARDS
    for index, shard in enumerate(SHARDS, start=1):
        if selector == shard["name"] or selector == str(index):
            return [shard]
    return None


def audit_coverage():
    """Every `test/**/*_test.dart` must belong to exactly one shard.

    Several shards use explicit file lists (to keep a measured split stable), so
    a newly added test file can belong to NO shard — it would then never run,
    and a full `run_tests.py` would still print a green TOTAL. That is the
    2026-07-10 allowlist failure mode: the gap is invisible at every layer that
    only looks at what IS listed. This check looks at what is NOT.

    Returns 0 when coverage is exact, 1 otherwise.
    """
    on_disk = set((REPO_ROOT / "test").rglob("*_test.dart"))
    seen = {}
    duplicated = []
    for shard in SHARDS:
        for path in shard_files(shard):
            if path in seen:
                duplicated.append((path, seen[path], shard["name"]))
            else:
                seen[path] = shard["name"]
    orphans = sorted(on_disk - set(seen))
    rc = 0
    for path in orphans:
        print(f"UNSHARDED: {path.relative_to(REPO_ROOT)} belongs to no shard — it would never run")
        rc = 1
    for path, first, second in duplicated:
        print(f"DUPLICATED: {path.relative_to(REPO_ROOT)} is in both {first} and {second}")
        rc = 1
    print(f"COVERAGE: {len(on_disk)} files on disk, {len(seen)} sharded, "
          f"{len(orphans)} unsharded, {len(duplicated)} duplicated")
    return rc


def print_table():
    print(f"{'#':>2}  {'shard':<14} {'files':>5} {'declared':>8}  paths")
    for index, shard in enumerate(SHARDS, start=1):
        files = shard_files(shard)
        print(f"{index:>2}  {shard['name']:<14} {len(files):>5} "
              f"{declared_count(files):>8}  {', '.join(shard['paths'])}")


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="run_tests.py",
        description="Run the Halcyon test suite in shards, each under the foreground timeout.")
    parser.add_argument("--shard", help="run one shard only, by name or 1-based index")
    parser.add_argument("--list", action="store_true", help="print the shard table and exit")
    parser.add_argument("--audit-coverage", action="store_true",
                        help="check every test file belongs to exactly one shard, then exit")
    args = parser.parse_args(argv)

    if args.list:
        print_table()
        return 0
    if args.audit_coverage:
        return audit_coverage()

    # A full run is only meaningful if the shards actually cover the suite; a
    # green TOTAL over an incomplete roster is worse than a red one.
    if not args.shard and audit_coverage() != 0:
        print("ERROR: shard coverage is incomplete — fix SHARDS before trusting a full run",
              file=sys.stderr)
        return 2

    shards = select_shards(args.shard)
    if shards is None:
        names = ", ".join(s["name"] for s in SHARDS)
        print(f"ERROR: unknown shard {args.shard!r}; known shards: {names}", file=sys.stderr)
        return 2

    results = [run_shard(shard) for shard in shards]
    passed = sum(r["passed"] for r in results)
    failed = sum(r["failed"] for r in results)
    rc = 0 if all(r["rc"] == 0 for r in results) else 1
    print(f"TOTAL: {passed} passed, {failed} failed, RC={rc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
