#!/usr/bin/env python3
"""M7 Task 7 -- RETIRED 2026-08-30 (AD-039, win-sidebar-thumbnails Ticket A).

This script's only job was applying ruling P-13 to `g3_sidebar_bench.dart`'s
CSV output (see the deleted ROW_RE and BASELINE_MS table in git history for
the full P-13 rule and the recorded baseline table). The sidebar RAW-decode
path it measured used to JPEG-re-encode every produced thumbnail; since
2026-08-30 that path stores oriented pixels directly and never re-encodes
(AD-039), so the timed operation no longer exists. `g3_sidebar_bench.dart`
was deleted rather than repaired (user ruling) because there is nothing left
to time that matches the recorded baseline's semantics.

Do not resurrect this verdict against the pixel path without a new baseline
recorded against that path's own timings -- the old BASELINE_MS numbers are
for a JPEG re-encode step that is gone.

Usage: python3 tool/m6_dng_gate/verdict_dng_extract.py <result-file>
Exit code: always 0 (retired, informational only).
"""
import sys


def main(argv):
    print("G3 sidebar bench retired 2026-08-30 (AD-039): the JPEG re-encode "
          "it timed no longer exists (sidebar RAW thumbnails now store "
          "oriented pixels directly). No verdict is produced. See "
          "tool/m6_dng_gate/README.md and git history for the retired "
          "P-13 rule and baseline table.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
