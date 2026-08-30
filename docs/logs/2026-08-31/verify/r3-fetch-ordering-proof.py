"""Targeted proof for the Phase-0/fetch ordering fix in scripts/build_apps.py.

Instrument: import build_apps, point Layout.decoder at a temp ceyx tree that has
plugin/pubspec.yaml but NO windows libraries (a clean checkout), stub the
host-OS gate (this machine is macOS), and record the `native_due` value that
build_target actually passes into check_target for `windows --fetch-native`.

What this proves: the ordering — the fetch decision is made before Phase 0, so
Phase 0 is told no local native build is due and therefore does not demand
VULKAN_SDK / HEIF dist / the S4 colour gate. It also proves --native always
still reports native_due=True (full Phase-0 native checks) and macOS is
unaffected. It does NOT prove a Windows build succeeds; only Windows CI can.
"""
import sys
import tempfile
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "scripts"))
import build_apps as B  # noqa: E402


def make_args(**kw):
    d = dict(check=True, clean=False, native="auto", fetch_native=False,
             skip_flutter_build=False, cfa_sample_dng=None, no_colour_gate=False,
             native_target=None, verbose=False)
    d.update(kw)
    return types.SimpleNamespace(**d)


def run(target, **kw):
    tmp = Path(tempfile.mkdtemp())
    decoder = tmp / "ceyx"
    (decoder / "plugin").mkdir(parents=True)
    (decoder / "plugin" / "pubspec.yaml").write_text("name: ceyx\n")
    layout = B.Layout(halcyon=tmp / "halcyon", decoder=decoder,
                      packaged=tmp / "packaged")
    (layout.halcyon).mkdir(parents=True, exist_ok=True)

    seen = {}
    orig_check, orig_supports = B.check_target, B.supports_target
    B.supports_target = lambda t: True
    B.check_target = lambda t, l, a, nd: seen.update(native_due=nd)
    try:
        B.build_target(target, layout, "release", make_args(**kw))
    finally:
        B.check_target, B.supports_target = orig_check, orig_supports
    return seen["native_due"]


cases = [
    ("windows fetch_native (clean checkout)", run("windows", fetch_native=True), False),
    ("windows auto, libs absent", run("windows"), False),  # auto-fetch also due
    ("windows --native always", run("windows", native="always"), True),
    ("macos auto (dylib absent in temp tree)", run("macos"), True),
    ("linux fetch_native", run("linux", fetch_native=True), False),
]
rc = 0
for name, got, want in cases:
    verdict = "PASS" if got == want else "FAIL"
    if got != want:
        rc = 1
    print(f"[{verdict}] {name}: native_due passed to check_target = {got} (want {want})")
sys.exit(rc)
