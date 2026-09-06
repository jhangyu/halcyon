#!/usr/bin/env python3
"""One-shot Halcyon perf capture (macOS).

Does the whole loop:
  1. Launches `flutter run -d macos --dart-define=HALCYON_PERF_LOG=1` with the
     PERF| event log redirected into docs/logs/<today>/ (via the
     HALCYON_PERF_LOG_DIR dart-define, so nothing lands in the system temp dir).
  2. Waits for the app to come up, then waits for you to press Enter (set up
     the window / open the photo folder first).
  3. Captures --duration seconds (default 20): `sample` call graph + the PERF|
     log slice covering exactly that window.
  4. Runs scripts/analyze_perf.py on both artifacts, then quits the app.

Usage:
  python3 scripts/capture_perf.py [--duration 20] [--label capture]
                                  [--keep-running]
"""

import argparse
import datetime
import os
import re
import subprocess
import sys
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANALYZE = os.path.join(REPO, "scripts", "analyze_perf.py")
READY_RE = re.compile(r"HALCYON_PERF_LOG active -- writing to (\S+)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--duration", type=int, default=20)
    ap.add_argument("--label", default="capture")
    ap.add_argument("--keep-running", action="store_true",
                    help="leave the app running after analysis")
    args = ap.parse_args()

    outdir = os.path.join(REPO, "docs", "logs",
                          datetime.date.today().isoformat())
    os.makedirs(outdir, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%H%M%S")
    base = os.path.join(outdir, f"{args.label}_{stamp}")

    print("launching flutter run -d macos (perf log on)...")
    proc = subprocess.Popen(
        ["flutter", "run", "-d", "macos",
         "--dart-define=HALCYON_PERF_LOG=1",
         f"--dart-define=HALCYON_PERF_LOG_DIR={outdir}"],
        cwd=REPO, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True)

    log_path = None

    def pump():
        nonlocal log_path
        for line in proc.stdout:
            sys.stdout.write("  | " + line)
            m = READY_RE.search(line)
            if m:
                log_path = m.group(1)

    t = threading.Thread(target=pump, daemon=True)
    t.start()

    deadline = time.time() + 300
    while log_path is None:
        if proc.poll() is not None:
            sys.exit("flutter run exited before the app started")
        if time.time() > deadline:
            sys.exit("timed out waiting for the app to start (5 min)")
        time.sleep(0.5)
    pid = int(re.search(r"halcyon_perf_(\d+)\.log", log_path).group(1))
    print(f"\napp up: pid={pid}\nPERF log: {log_path}")

    # Stray newlines buffered during the build make a bare input() return
    # instantly (observed twice); requiring a literal token is immune to that.
    print("\n" + "=" * 70)
    while input(f"READY — set up the window, then type 's' + Enter to START "
                f"the {args.duration}s capture: ").strip().lower() != "s":
        print("(waiting — type 's' then Enter when ready)")
    print(f"START {datetime.datetime.now():%H:%M:%S} — capturing "
          f"{args.duration}s, do your loading now...")

    log_start = os.path.getsize(log_path) if os.path.exists(log_path) else 0
    sample_path = f"{base}_sample.txt"
    print(f"capturing... (sample {args.duration}s @1ms)")
    rc = subprocess.run(["sample", str(pid), str(args.duration), "1",
                         "-f", sample_path],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.STDOUT).returncode
    time.sleep(1.0)  # let the app's 300ms periodic flush land the last events

    artifacts = []
    if rc == 0 and os.path.exists(sample_path):
        artifacts.append(("sample", sample_path))
    else:
        print(f"!! sample failed (rc={rc})")

    if os.path.exists(log_path):
        with open(log_path, "rb") as fh:
            fh.seek(log_start)
            chunk = fh.read()
        slice_path = f"{base}_perf.log"
        with open(slice_path, "wb") as fh:
            fh.write(chunk)
        if chunk.strip():
            artifacts.append(("log", slice_path))
        else:
            print("!! PERF log grew 0 bytes during the capture window")

    if not args.keep_running:
        print("quitting app...")
        try:
            proc.stdin.write("q")
            proc.stdin.flush()
            proc.wait(timeout=15)
        except Exception:
            proc.terminate()

    print(f"\nartifacts under {outdir}/:")
    for _, p in artifacts:
        print(f"  {os.path.basename(p)}")
    for mode, p in artifacts:
        print(f"\n{'=' * 70}\n== analyze_perf.py {mode} "
              f"{os.path.basename(p)}\n{'=' * 70}")
        subprocess.run([sys.executable, ANALYZE, mode, p])
    return 0


if __name__ == "__main__":
    sys.exit(main())
