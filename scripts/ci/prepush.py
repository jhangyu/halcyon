"""`ci.py prepush` -- LOCAL-ONLY pre-push gate (user rulings 2026-09-30 and
2026-10-03, `.claude/CLAUDE.md` "本機 CI 先行").

One merged gate: it fresh-clones the COMMITTED state of this repo (plus the
sibling ceyx checkout at the ref the workflows pin) into a scratch directory and,
inside that clone, runs every locally-runnable workflow step AND the automated
test suite. Remote CI stays compile-only, so `prepush` must never appear in a
workflow file: the `workflow-lint` step and test_policy.py both fail if it does.

Gate scope is DERIVED from .github/workflows, never mirrored by hand (the
2026-09-30 export-manifest incident: copying only the build legs dropped a
guard job). Every job is enumerated; a job is excluded only by an entry in
EXCLUDED_JOBS stating why. Each `run: python3 scripts/ci.py ...` line of an
included job becomes a step; matrix legs (`{os: R, target: T}` lines) become one
step per target whose runner equals this host (targets.RUNNER_HOST). Identical
argv from two workflows (ci.yml and release.yml both build) runs once.

Both clones are checked out with core.autocrlf=false, i.e. the committed bytes
exactly, independent of the host's git config: several tests pin source text
with `\\n` needles, and a CRLF checkout (Git for Windows' default) fails them on
Windows only while macOS passes -- a host artifact, not a property of the commit.

Prebuilt ceyx libraries: build_apps.py's --fetch-native reads its pinned
release cache (build/ceyx-release-cache/<tag>/) before downloading and re-checks
every cached file's sha256 against the pin. The clone's cache is seeded with
pin-verified copies from this checkout's cache and from a persistent cache
beside the scratch dir, and whatever the build had to download is copied back
there, so the build argv stays byte-identical to CI's and bytes are fetched once.

Legs whose runner is another Linux machine run in docker when one answers
(targets.RUNNER_CONTAINER, container_leg.py: the same derivation, inside the
runner's image); without docker each is a printed, counted skip. Legs neither
runnable here nor containerised are counted as excluded_host.

Steps (see `--list`): clone, workflow-lint, toolchain, <derived workflow
steps>, container-<runner>..., tests. Each step writes `<log-dir>/<step>.txt`
whose last line is `RC=<n>`, written by this process. A full run ends with one
`PREPUSH-SUMMARY steps=<n> failed=<k> flaky_known= quarantined_files= excluded_host= skipped=`
line; `--step NAME` runs one step against the existing clone (refused if the
clone is missing or not at HEAD) and ends with `PREPUSH-PARTIAL step=NAME`
instead, so a single green step never reads as a green gate. The scratch
workdir carries a marker file; a directory without it is never deleted.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import stat
import sys
import tempfile
import time
from pathlib import Path

from . import report, run, targets

PACKAGE_VERSION = "v0.0.0-prepush"

EXCLUDED_JOBS = {
    "auto-release": "publishes a GitHub release (needs GITHUB_TOKEN, side effect); "
                    "builds and checks nothing",
}

TEST_STEP = "tests"

# Known timing-flaky test FILES (user ruling 2026-10-03, file-level). A failure
# of any test inside one of these files is counted as flaky_known and printed --
# never a pass, never silent. Any failure in ANY other file, and a file that
# fails to load at all, stays hard red. There is no retry anywhere.
#
# Frozen: additions are lead-approved only. The list is campaign input -- the
# Windows de-flake work item consumes it. Each entry cites the artifacts under
# tmp/memprofile/prepush-hal/ where that file's tests failed and then passed
# with no code change. Seven gate runs: run0-red.log, run1.log, run2.log,
# run3.log, run4.log (full gate), quiet-tests.log (idle machine) and
# serial-diag.txt (`-j 1`, idle machine), plus the per-file isolation reruns
# isolate-rerun.txt / isolate-admission.txt. The idle and serial runs ruled out
# machine load and cross-file parallelism as the cause.
_PIPE_TESTS = "test/services/image_pipeline/"
QUARANTINED_FILES = {
    "test/providers/app_state_open_with_test.dart": "run0-red.log",
    # lead-approved addition (TC-860 timing failure in a verifier run)
    "test/providers/app_state_counts_test.dart": "v-r3D-tests.log:1930",
    _PIPE_TESTS + "admission_gate_test.dart":
        "run2.log, run3.log, run4.log, isolate-admission.txt",
    _PIPE_TESTS + "decode_lane_pool_test.dart": "serial-diag.txt",
    _PIPE_TESTS + "encode_test.dart": "quiet-tests.log, serial-diag.txt",
    _PIPE_TESTS + "image_preload_controller_test.dart":
        "run0-red.log, run1.log, quiet-tests.log, serial-diag.txt, isolate-rerun.txt",
    _PIPE_TESTS + "image_preload_flow_test.dart":
        "run1.log, run3.log, run4.log, isolate-rerun.txt",
    _PIPE_TESTS + "native_orientation_pointer_test.dart": "run4.log, quiet-tests.log",
    _PIPE_TESTS + "pacing_test.dart": "quiet-tests.log, serial-diag.txt",
    _PIPE_TESTS + "q70_out_of_window_test.dart": "run4.log, quiet-tests.log",
    _PIPE_TESTS + "q70_payload_publish_test.dart": "run1.log",
    _PIPE_TESTS + "tier_two_test.dart": "quiet-tests.log, serial-diag.txt",
    _PIPE_TESTS + "yuv420_direct_encode_routing_test.dart": "serial-diag.txt",
    _PIPE_TESTS + "yuv420_pointer_encode_address_test.dart":
        "run1.log, run4.log, isolate-rerun.txt",
}

_SHARD_RE = re.compile(r"^SHARD (\S+): .* RC=(\d+) log=(.+?)\s*$", re.MULTILINE)
_STRUCTURAL = ("(setUpAll)", "(tearDownAll)")

_JOB_RE = re.compile(r"^  ([\w-]+):\s*$")
_RUN_RE = re.compile(r"^\s*run:\s*(.*?)\s*$")
_MATRIX_RE = re.compile(r"^\s*-\s*\{os:\s*([\w.-]+)\s*,\s*target:\s*([\w.-]+)\s*(?:,[^}]*)?\}")
_CEYX_REF_RE = re.compile(r"^\s*ref:\s*([0-9a-f]{40})\s*$")
_FLUTTER_RE = re.compile(r"flutter-version:\s*'([^']+)'")
_EXPR_SUBST = {
    "${{ matrix.target }}": "{target}",
    "${{ env.HALCYON_VERSION }}": PACKAGE_VERSION,
}


# --------------------------------------------------------------------------
# Workflow parsing (pure text; no YAML dependency, stdlib only)
# --------------------------------------------------------------------------

def _workflow_files(workflows_dir):
    return sorted(Path(workflows_dir).glob("*.yml")) + sorted(Path(workflows_dir).glob("*.yaml"))


def workflow_hits(workflows_dir):
    """Every `file:line` in a workflow that mentions prepush (must be empty)."""
    return [f"{wf.name}:{n}: {line.strip()}"
            for wf in _workflow_files(workflows_dir)
            for n, line in enumerate(wf.read_text(encoding="utf-8").splitlines(), start=1)
            if "prepush" in line]


def workflow_jobs(workflows_dir):
    """[(workflow_name, job_id, [lines])] in file order."""
    jobs = []
    for wf in _workflow_files(workflows_dir):
        lines = wf.read_text(encoding="utf-8").splitlines()
        in_jobs = False
        for line in lines:
            if line.startswith("jobs:"):
                in_jobs = True
                continue
            if in_jobs and line and not line.startswith((" ", "#")):
                in_jobs = False
            if not in_jobs:
                continue
            m = _JOB_RE.match(line)
            if m:
                jobs.append((wf.name, m.group(1), []))
            elif jobs and jobs[-1][0] == wf.name:
                jobs[-1][2].append(line)
    return jobs


def host_key():
    from . import assertions
    return assertions.host_platform(), targets.HOST_ARCH.get(platform.machine().lower())


def derive_plan(workflows_dir, host=None):
    """Returns (steps, derivation, errors).

    steps: ordered [(name, argv_tail)] where argv_tail follows `scripts/ci.py`.
    derivation: human-readable `JOB ...` lines (included/excluded + reason).
    errors: anything the derivation could not classify (workflow-lint fails).
    """
    host = host or host_key()
    steps, derivation, errors, seen = [], [], [], set()
    for wf_name, job, lines in workflow_jobs(workflows_dir):
        label = f"{wf_name}:{job}"
        if job in EXCLUDED_JOBS:
            derivation.append(f"JOB {label} -> excluded: {EXCLUDED_JOBS[job]}")
            continue
        legs = [(m.group(1), m.group(2)) for m in map(_MATRIX_RE.match, lines) if m]
        unknown = sorted({r for r, _ in legs if r not in targets.RUNNER_HOST})
        if unknown:
            errors.append(f"{label}: runner label(s) {unknown} have no targets.RUNNER_HOST entry")
        runs = [m.group(1) for m in map(_RUN_RE.match, lines) if m]
        if not runs:
            errors.append(f"{label}: no `run:` lines found; classify it in EXCLUDED_JOBS")
            continue
        if legs:
            local = [t for r, t in legs if targets.RUNNER_HOST.get(r) == host]
            for r, t in legs:
                if t in local:
                    continue
                if r in targets.RUNNER_CONTAINER:
                    derivation.append(f"JOB {label}[{t}] -> container step container-{r} "
                                      f"(docker {targets.RUNNER_CONTAINER[r]})")
                else:
                    derivation.append(f"JOB {label}[{t}] -> excluded: runner {r} is "
                                      f"{targets.RUNNER_HOST.get(r)}, host is {host}")
        else:
            local = [None]
        for target in local:
            names = []
            for raw in runs:
                tail, err = _render_run(raw, target)
                if err:
                    errors.append(f"{label}: {err}")
                    continue
                name = tail[0] if target is None else f"{tail[0]}-{target}"
                if tuple(tail) not in seen:
                    seen.add(tuple(tail))
                    steps.append((name, tail))
                    names.append(name)
                else:
                    names.append(f"{name}(dup)")
            leg = "" if target is None else f"[{target}]"
            derivation.append(f"JOB {label}{leg} -> included: {', '.join(names)}")
    return steps, derivation, errors


def leg_steps(steps):
    """The target-matrix steps of a derived plan (those carrying --target)."""
    return [(name, tail) for name, tail in steps if "--target" in tail]


def _render_run(raw, target):
    prefix = "python3 scripts/ci.py "
    if "prepush" in raw:
        # Never a step: a workflow running the gate would make the gate run
        # itself, and the inner run deletes the outer run's clone.
        return None, f"workflow invokes the local-only prepush gate: {raw!r}"
    if not raw.startswith(prefix):
        return None, f"run line is not `{prefix}...`: {raw!r}"
    text = raw[len(prefix):]
    for expr, value in _EXPR_SUBST.items():
        text = text.replace(expr, value)
    if "${{" in text:
        return None, f"unresolvable expression in {raw!r}"
    if "{target}" in text:
        if target is None:
            return None, f"matrix.target used outside a target matrix: {raw!r}"
        text = text.replace("{target}", target)
    return shlex.split(text), None


def workflow_pins(workflows_dir):
    """(ceyx_refs, flutter_versions) as sets over every workflow file."""
    refs, versions = set(), set()
    for wf in _workflow_files(workflows_dir):
        lines = wf.read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines):
            if "repository: jhangyu/ceyx" in line:
                for follow in lines[i + 1:i + 3]:
                    m = _CEYX_REF_RE.match(follow)
                    if m:
                        refs.add(m.group(1))
            m = _FLUTTER_RE.search(line)
            if m:
                versions.add(m.group(1))
    return refs, versions


# --------------------------------------------------------------------------
# Scratch layout
# --------------------------------------------------------------------------

class Layout:
    def __init__(self, source, workdir):
        self.source = Path(source).resolve()
        self.work = Path(workdir).resolve()
        self.clone = self.work / "Halcyon"
        self.ceyx = self.work / "ceyx"
        self.cache = self.work.with_name(self.work.name + "-cache")
        self.flaky_known = 0
        self.skipped = 0


WORKDIR_MARKER = ".halcyon-prepush-workdir"


def remove_workdir(work):
    """Deletes [work] only if the gate created it (marker present); a --workdir
    pointing at anything else -- a repo, a home dir -- is refused, not wiped."""
    work = Path(work)
    if not work.exists():
        return
    if not (work / WORKDIR_MARKER).is_file():
        raise RuntimeError(f"refusing to delete {work}: no {WORKDIR_MARKER} marker, "
                           "so prepush did not create it")
    _rmtree(work)


def _git_head(repo):
    result = run.run(["git", "-C", os.fspath(repo), "rev-parse", "HEAD"])
    return result.stdout.strip() if result.returncode == 0 else None


def _rmtree(path):
    def _writable(func, target, _exc):
        os.chmod(target, stat.S_IWRITE)
        func(target)
    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=_writable)
    else:
        shutil.rmtree(path, onerror=_writable)


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _pin(clone):
    return json.loads((clone / "scripts" / "ceyx_release_pin.json").read_text(encoding="utf-8"))


def _pinned_names_by_digest(pin):
    digests = {v["sha256"].lower(): v["archive"] for v in pin["assets"].values()}
    digests[pin["lock"]["sha256"].lower()] = pin["lock"]["asset"]
    return digests


def _seed(src_dirs, dest_dir, pin):
    """Copies every file whose name AND sha256 match a pin entry; returns log lines."""
    wanted = _pinned_names_by_digest(pin)
    out = []
    for src in src_dirs:
        if not src.is_dir():
            out.append(f"SEED-SOURCE-ABSENT {src}")
            continue
        for f in sorted(p for p in src.iterdir() if p.is_file()):
            target = dest_dir / f.name
            if target.exists():
                continue
            digest = _sha256(f)
            if wanted.get(digest) != f.name:
                continue
            dest_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, target)
            out.append(f"SEED {f.name} sha256={digest} from {src}")
    return out


def _cache_dir(repo, pin):
    return repo / "build" / "ceyx-release-cache" / pin["tag"]


# --------------------------------------------------------------------------
# Steps
# --------------------------------------------------------------------------

def _step_clone(layout, log_path):
    out = []
    rc = 1
    try:
        head = _git_head(layout.source)
        if head is None:
            raise RuntimeError(f"{layout.source} is not a git repository")
        remove_workdir(layout.work)
        layout.work.mkdir(parents=True)
        (layout.work / WORKDIR_MARKER).write_text("created by ci.py prepush\n", encoding="utf-8")
        argv = ["git", "-c", "core.autocrlf=false", "clone", "--quiet",
                "--config", "core.autocrlf=false",
                os.fspath(layout.source), os.fspath(layout.clone)]
        r = run.run(argv)
        out.append(f"$ {' '.join(argv)}\n{r.stdout}{r.stderr}RC={r.returncode}")
        if r.returncode:
            raise RuntimeError("git clone of this repo failed")
        clone_head = _git_head(layout.clone)
        out.append(f"SOURCE-HEAD {head}\nCLONE-HEAD {clone_head}")
        if clone_head != head:
            raise RuntimeError("clone HEAD differs from source HEAD")
        refs, _ = workflow_pins(layout.clone / ".github" / "workflows")
        if len(refs) != 1:
            raise RuntimeError(f"workflows must pin exactly one ceyx ref, found {sorted(refs)}")
        ref = refs.pop()
        ceyx_src = layout.source.parent / "ceyx"
        for argv in (["git", "clone", "--quiet", "--no-checkout",
                      "--config", "core.autocrlf=false", os.fspath(ceyx_src),
                      os.fspath(layout.ceyx)],
                     ["git", "-C", os.fspath(layout.ceyx), "checkout", "--quiet", "--detach", ref]):
            r = run.run(argv)
            out.append(f"$ {' '.join(argv)}\n{r.stdout}{r.stderr}RC={r.returncode}")
            if r.returncode:
                raise RuntimeError(f"ceyx clone/checkout of pinned ref {ref} failed "
                                   f"(is {ref} present in {ceyx_src}?)")
        out.append(f"CEYX-REF {ref} (pinned by the workflows) CEYX-HEAD {_git_head(layout.ceyx)}")
        pin = _pin(layout.clone)
        out += _seed([_cache_dir(layout.source, pin), layout.cache / pin["tag"]],
                     _cache_dir(layout.clone, pin), pin)
        rc = 0
    except (OSError, RuntimeError) as exc:
        out.append(f"ERROR: {exc}")
    report.write_log(log_path, header="prepush clone", body="\n".join(out), rc=rc)
    return rc


def _step_workflow_lint(layout, log_path):
    wf_dir = layout.clone / ".github" / "workflows"
    hits = workflow_hits(wf_dir)
    _, derivation, errors = derive_plan(wf_dir)
    refs, versions = workflow_pins(wf_dir)
    out = [f"PREPUSH-IN-WORKFLOW {h}" for h in hits]
    out += derivation
    out += [f"UNCLASSIFIED {e}" for e in errors]
    if len(refs) != 1:
        out.append(f"PIN-DRIFT ceyx refs {sorted(refs)}")
    if len(versions) != 1:
        out.append(f"PIN-DRIFT flutter versions {sorted(versions)}")
    rc = 1 if (hits or errors or len(refs) != 1 or len(versions) != 1) else 0
    report.write_log(log_path, header="prepush workflow-lint", body="\n".join(out), rc=rc)
    return rc


def _step_toolchain(layout, log_path):
    _, versions = workflow_pins(layout.clone / ".github" / "workflows")
    r = run.run(["flutter", "--version", "--machine"])
    text = r.stdout
    observed = None
    try:
        observed = json.loads(text[text.index("{"):]).get("frameworkVersion")
    except ValueError:
        pass
    out = [f"WORKFLOW flutter-version {sorted(versions)}", f"LOCAL flutter {observed}",
           text + r.stderr]
    rc = 0 if (r.returncode == 0 and versions == {observed}) else 1
    report.write_log(log_path, header="flutter --version --machine", body="\n".join(out), rc=rc)
    return rc


def _step_ci(layout, tail, log_path):
    argv = [sys.executable, os.fspath(layout.clone / "scripts" / "ci.py"), *tail]
    rc = run.run_logged(argv, log_path, cwd=layout.clone).returncode
    pin = _pin(layout.clone)
    if _cache_dir(layout.clone, pin).is_dir():
        for line in _seed([_cache_dir(layout.clone, pin)], layout.cache / pin["tag"], pin):
            print(f"CACHE-BACK {line}")
    return rc


def docker_unavailable_reason():
    """None when a docker daemon answers; otherwise why the container legs skip."""
    if shutil.which("docker") is None:
        return "docker is not installed on this host"
    if run.run(["docker", "info"]).returncode != 0:
        return "docker is installed but its daemon does not answer `docker info`"
    return None


def _step_container(layout, runner, log_path):
    """Runs one container leg (targets.RUNNER_CONTAINER) via container_leg.py.
    Without docker it is a printed, counted skip -- never a silent pass."""
    reason = docker_unavailable_reason()
    if reason:
        layout.skipped += 1
        line = f"PREPUSH-SKIP container-{runner}: {reason}"
        print(line)
        report.write_log(log_path, header=f"prepush container-{runner}", body=line, rc=0)
        return 0
    image, docker_platform = targets.RUNNER_CONTAINER[runner]
    refs, _ = workflow_pins(layout.clone / ".github" / "workflows")
    out_dir = log_path.with_suffix("")
    out_dir.mkdir(parents=True, exist_ok=True)
    bootstrap = (
        "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "
        f"--no-install-recommends {' '.join(targets.CONTAINER_APT_PACKAGES)} && "
        f"python3 /in/Halcyon/scripts/ci/container_leg.py --runner {runner} "
        f"--ceyx-ref {sorted(refs)[0]} --in /in --out /out"
    )
    argv = ["docker", "run", "--rm", "--platform", docker_platform,
            "-v", f"{os.fspath(layout.work)}:/in:ro", "-v", f"{os.fspath(out_dir)}:/out",
            image, "sh", "-c", bootstrap]
    return run.run_logged(argv, log_path, cwd=layout.work).returncode


def _strip_clone(path, clone):
    prefix = clone.as_posix().rstrip("/") + "/"
    path = Path(path).as_posix()
    return path[len(prefix):] if path.startswith(prefix) else path


def test_results(json_text, clone):
    """[(test file, test name, outcome)] from a `flutter test` JSON report;
    outcome is pass / skip / fail. A test that started but never got a
    testDone is a failure. A test with any `error` event is a failure
    even when its testDone said success: a test can fail AFTER it completed
    (async work outliving it), and that error arrives as a later event.
    Hidden entries (setUpAll/tearDownAll hooks, `loading`) are kept only when
    they failed."""
    suites, tests, done, errored = {}, {}, {}, set()
    for line in json_text.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        if kind == "suite":
            suites[event["suite"]["id"]] = event["suite"]["path"]
        elif kind == "testStart":
            test = event["test"]
            tests[test["id"]] = (suites.get(test["suiteID"], "?"), test["name"])
        elif kind == "error":
            errored.add(event.get("testID"))
        elif kind == "testDone":
            done[event.get("testID")] = event
    results = []
    for test_id, (path, name) in tests.items():
        event = done.get(test_id, {})
        if test_id in errored or not event or event.get("result") != "success":
            # No testDone at all = started but never finished (a crash late in
            # the file); counted as failed, never silently dropped.
            outcome = "fail"
        elif event.get("skipped"):
            outcome = "skip"
        else:
            outcome = "pass"
        if event.get("hidden") and outcome != "fail":
            continue
        results.append((_strip_clone(path, clone), name, outcome))
    return results


def judge_tests(run_tests_output, raw_rc, clone):
    """Returns (rc, flaky_known, lines). Green only when every red shard is
    fully explained by timing-sized failures inside QUARANTINED_FILES.
    Hard red regardless of the list: a failure in any other file; a file that
    fails to load; a setUpAll/tearDownAll failure (it silently cancels the
    tests behind it); a listed file that ran no tests; a listed file where
    more than half of the tests that ran failed (not timing-flake territory);
    a shard without its JSON report."""
    lines, flaky, unexplained = [], set(), False
    shards = _SHARD_RE.findall(run_tests_output)
    if raw_rc != 0 and not any(rc != "0" for _, rc, _ in shards):
        lines.append(f"TESTS-RED run_tests.py RC={raw_rc} with no red shard (table/coverage error)")
        unexplained = True
    ran, failed_by_file = {}, {}
    for shard, rc, log in shards:
        report_path = Path(log).with_suffix(".json")
        if not report_path.is_file():
            lines.append(f"TESTS-RED shard {shard}: no JSON report at {report_path}")
            unexplained = True
            continue
        results = test_results(report_path.read_text(encoding="utf-8", errors="replace"), clone)
        failures = [(f, n) for f, n, outcome in results if outcome == "fail"]
        for test_file, name, outcome in results:
            if outcome != "skip":
                ran[test_file] = ran.get(test_file, 0) + 1
        if rc != "0" and not failures:
            lines.append(f"TESTS-RED shard {shard} RC={rc} with no failing test in its report")
            unexplained = True
        for test_file, name in sorted(failures):
            test = f"{test_file}: {name}"
            structural = name.startswith("loading ") or name.endswith(_STRUCTURAL)
            if test_file in QUARANTINED_FILES and not structural:
                flaky.add(test)
                failed_by_file[test_file] = failed_by_file.get(test_file, 0) + 1
                lines.append(f"FLAKY-KNOWN {test} (quarantined file; evidence: "
                             f"{QUARANTINED_FILES[test_file]})")
            else:
                lines.append(f"TESTS-RED {test}")
                unexplained = True
    if shards:
        for test_file in sorted(QUARANTINED_FILES):
            executed = ran.get(test_file, 0)
            failed = failed_by_file.get(test_file, 0)
            if executed == 0:
                lines.append(f"TESTS-RED quarantined file {test_file} ran no tests")
                unexplained = True
            elif failed * 2 > executed:
                lines.append(f"TESTS-RED quarantined file {test_file}: {failed} of {executed} "
                             "tests failed (>50%: wholesale failure, not a timing flake)")
                unexplained = True
    rc = 1 if unexplained else 0
    lines.append(f"TESTS-VERDICT raw_rc={raw_rc} flaky_known={len(flaky)} rc={rc}")
    return rc, len(flaky), lines


def _step_tests(layout, log_path):
    argv = [sys.executable, os.fspath(layout.clone / "scripts" / "run_tests.py")]
    r = run.run(argv, cwd=layout.clone)
    output = r.stdout + r.stderr
    rc, layout.flaky_known, lines = judge_tests(output, r.returncode, layout.clone)
    for line in lines:
        if line.startswith(("FLAKY-KNOWN", "TESTS-RED")):
            print(line)
    report.write_log(log_path, header=" ".join(r.argv),
                     body=output + "\n" + "\n".join(lines), rc=rc)
    return rc


def all_steps(layout):
    """[(name, callable(log_path) -> rc)] in execution order, plus derivation."""
    wf_dir = layout.clone / ".github" / "workflows"
    if not wf_dir.is_dir():
        wf_dir = layout.source / ".github" / "workflows"
    derived, derivation, _ = derive_plan(wf_dir)
    steps = [
        ("clone", lambda p: _step_clone(layout, p)),
        ("workflow-lint", lambda p: _step_workflow_lint(layout, p)),
        ("toolchain", lambda p: _step_toolchain(layout, p)),
    ]
    steps += [(name, (lambda tail: lambda p: _step_ci(layout, tail, p))(tail))
              for name, tail in derived]
    container_runners = [r for r in targets.RUNNER_CONTAINER
                         if any(f"container step container-{r} " in d for d in derivation)]
    steps += [(f"container-{r}", (lambda r: lambda p: _step_container(layout, r, p))(r))
              for r in container_runners]
    steps.append((TEST_STEP, lambda p: _step_tests(layout, p)))
    return steps, derivation, wf_dir


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def default_workdir():
    return Path(tempfile.gettempdir()) / "halcyon-prepush"


def main(repo_root, step=None, workdir=None, log_dir=None, keep=False, list_only=False):
    os.environ["PYTHONUTF8"] = "1"
    layout = Layout(repo_root, workdir or default_workdir())
    log_dir = Path(log_dir or Path(repo_root) / "build" / "prepush").resolve()
    steps, derivation, wf_dir = all_steps(layout)
    names = [n for n, _ in steps]

    if list_only:
        print(f"WORKFLOWS {wf_dir}")
        print(f"HOST {host_key()}")
        for line in derivation:
            print(line)
        for n, _ in steps:
            print(f"STEP {n}")
        return 0
    if step == "cleanup":
        try:
            remove_workdir(layout.work)
        except RuntimeError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 1
        print(f"PREPUSH-CLEANUP removed {layout.work}")
        return 0
    if step is not None and step not in names:
        print(f"ERROR: unknown step {step!r}; steps: {', '.join(names)}, cleanup", file=sys.stderr)
        return 2
    selected = [s for s in steps if step is None or s[0] == step]

    if step not in (None, "clone"):
        head, clone_head = _git_head(layout.source), _git_head(layout.clone)
        if head is None or clone_head != head:
            print(f"ERROR: clone at {layout.clone} is missing or not at HEAD "
                  f"(source {head}, clone {clone_head}); run --step clone first", file=sys.stderr)
            print(f"PREPUSH-PARTIAL step={step} RC=1 (clone missing or stale)")
            return 1

    log_dir.mkdir(parents=True, exist_ok=True)
    summary_lines = [f"SOURCE {layout.source} HEAD {_git_head(layout.source)}",
                     f"CLONE {layout.clone}"]
    print(summary_lines[0])
    failed = 0
    started = time.monotonic()
    index = 0
    while index < len(selected):
        name, fn = selected[index]
        log_path = log_dir / f"{name}.txt"
        t0 = time.monotonic()
        rc = fn(log_path)
        line = (f"PREPUSH-STEP {name} RC={rc} elapsed={time.monotonic() - t0:.1f}s "
                f"log={log_path}")
        print(line, flush=True)
        summary_lines.append(line)
        index += 1
        if rc:
            failed += 1
        if name == "clone" and step is None:
            if rc:
                for rest, _ in selected[index:]:
                    line = f"PREPUSH-STEP {rest} RC=NOT-RUN (clone failed)"
                    print(line)
                    summary_lines.append(line)
                    failed += 1
                break
            # Re-derive from the FRESH clone's workflows, not whatever was on
            # disk before it (a previous clone or the working tree).
            selected, derivation, _ = all_steps(layout)
            summary_lines += derivation

    ci_logs = layout.clone / "build" / "ci-logs"
    if ci_logs.is_dir():
        shutil.copytree(ci_logs, log_dir / "clone-ci-logs", dirs_exist_ok=True)
    excluded_host = sum("-> excluded: runner" in line for line in derivation)
    if layout.flaky_known:
        print(f"WARNING: {layout.flaky_known} quarantined known-flaky test failure(s) -- "
              "counted as flaky_known, NOT as passed (see FLAKY-KNOWN lines)")
    counters = (f"failed={failed} flaky_known={layout.flaky_known} "
                f"quarantined_files={len(QUARANTINED_FILES)} "
                f"excluded_host={excluded_host} skipped={layout.skipped} "
                f"elapsed={time.monotonic() - started:.1f}s")
    rc = 1 if failed else 0
    # A single step is never reported with the full-gate line: a green
    # `--step X` must not be mistakable for a green gate.
    summary = (f"PREPUSH-SUMMARY steps={len(selected)} {counters}" if step is None
               else f"PREPUSH-PARTIAL step={step} RC={rc} {counters}")
    print(summary)
    summary_lines.append(summary)
    report.write_log(log_dir / ("prepush.txt" if step is None else f"prepush-{step}.summary.txt"),
                     header="ci.py prepush" + ("" if step is None else f" --step {step}"),
                     body="\n".join(summary_lines), rc=rc)
    if step is None and not failed and not keep:
        try:
            remove_workdir(layout.work)
            print(f"PREPUSH-CLEANUP removed {layout.work}")
        except (OSError, RuntimeError) as exc:
            print(f"WARN: cleanup of {layout.work} failed: {exc}")
    elif step is None:
        print(f"PREPUSH-KEPT {layout.work}")
    return rc
