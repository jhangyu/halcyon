"""Container side of a `ci.py prepush` container leg. Runs INSIDE the docker
image prepush.py starts (targets.RUNNER_CONTAINER); never on the host.

    python3 container_leg.py --runner LABEL --ceyx-ref SHA --in /in --out /out

/in holds prepush's scratch clones (read-only): they are cloned again into an
empty dir here, so the leg sees committed state only. The steps are the SAME
derivation prepush.py uses (`derive_plan` with this runner as the host),
restricted to the target-matrix steps -- the host already ran the
host-independent ones. Each step writes /out/<step>.txt ending `RC=<n>`.

Instrument check: a system libheif/libde265 would satisfy the decoder's dlopen and blind the
capability assertions, so if the image has any, they are hidden (reversible
rename) and assert-capabilities is re-run as `<step>-system-libs-hidden`.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

HIDE_SUFFIX = ".prepush-hidden"


def _system_codec_libs():
    out = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
    paths = set()
    for line in out.splitlines():
        if ("libheif" in line or "libde265" in line) and "=> " in line:
            paths.add(line.split("=> ", 1)[1].strip())
    return sorted(paths)


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--runner", required=True)
    p.add_argument("--ceyx-ref", required=True)
    p.add_argument("--in", dest="src", required=True)
    p.add_argument("--out", required=True)
    args = p.parse_args(argv)
    src, out = Path(args.src), Path(args.out)
    work = Path("/work")
    subprocess.run(["git", "config", "--global", "--add", "safe.directory", "*"], check=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    for argv_ in (["git", "clone", "--quiet", os.fspath(src / "Halcyon"), os.fspath(work / "Halcyon")],
                  ["git", "clone", "--quiet", "--no-checkout", os.fspath(src / "ceyx"),
                   os.fspath(work / "ceyx")],
                  ["git", "-C", os.fspath(work / "ceyx"), "checkout", "--quiet", "--detach",
                   args.ceyx_ref]):
        subprocess.run(argv_, check=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    clone = work / "Halcyon"
    sys.path.insert(0, os.fspath(clone / "scripts"))
    from ci import prepush, run, targets  # noqa: PLC0415

    os.environ["PYTHONUTF8"] = "1"
    os.environ["CI"] = "true"
    github_path = out / "github_path"
    github_path.write_text("", encoding="utf-8")
    os.environ["GITHUB_PATH"] = os.fspath(github_path)

    host = targets.RUNNER_HOST[args.runner]
    steps, _, errors = prepush.derive_plan(clone / ".github" / "workflows", host=host)
    if errors:
        print("\n".join(f"UNCLASSIFIED {e}" for e in errors))
        return 1
    _, flutter_versions = prepush.workflow_pins(clone / ".github" / "workflows")
    failed = 0
    for name, tail in prepush.leg_steps(steps):
        if tail[0] != "provision" and shutil.which("flutter") is None:
            # The workflow's `uses: subosito/flutter-action` step has no run
            # line to derive; legs whose provision does not install Flutter
            # get the same pinned SDK the workflows name.
            rc = run.run_logged([sys.executable, os.fspath(clone / "scripts" / "ci" / "install_flutter.py"),
                                 "--tag", sorted(flutter_versions)[0], "--dest", "~/flutter"],
                                out / "install-flutter.txt", cwd=clone).returncode
            print(f"CONTAINER-STEP install-flutter RC={rc}", flush=True)
            _apply_github_path(github_path)
            if rc:
                failed += 1
                break
        rc = run.run_logged([sys.executable, os.fspath(clone / "scripts" / "ci.py"), *tail],
                            out / f"{name}.txt", cwd=clone).returncode
        print(f"CONTAINER-STEP {name} RC={rc}", flush=True)
        failed += rc != 0
        _apply_github_path(github_path)
        if tail[0] == "assert-capabilities" and rc == 0:
            failed += _assert_with_system_libs_hidden(name, tail, clone, out, run)
    print(f"CONTAINER-SUMMARY runner={args.runner} failed={failed}")
    return 1 if failed else 0


def _apply_github_path(github_path):
    """Emulates the runner: entries a step appended to $GITHUB_PATH reach later steps."""
    added = [l for l in github_path.read_text(encoding="utf-8").splitlines() if l]
    os.environ["PATH"] = os.pathsep.join([*reversed(added), os.environ["PATH"]])
    github_path.write_text("", encoding="utf-8")


def _assert_with_system_libs_hidden(name, tail, clone, out, run):
    libs = _system_codec_libs()
    print(f"SYSTEM-CODEC-LIBS {len(libs)} {libs}")
    if not libs:
        return 0
    hidden = []
    try:
        for lib in libs:
            os.rename(lib, lib + HIDE_SUFFIX)
            hidden.append(lib)
        subprocess.run(["ldconfig"], check=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        rc = run.run_logged([sys.executable, os.fspath(clone / "scripts" / "ci.py"), *tail],
                            out / f"{name}-system-libs-hidden.txt", cwd=clone).returncode
    finally:
        for lib in hidden:
            os.rename(lib + HIDE_SUFFIX, lib)
        subprocess.run(["ldconfig"], check=False, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    print(f"CONTAINER-STEP {name}-system-libs-hidden RC={rc}", flush=True)
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main())
