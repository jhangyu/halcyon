# CI Conventions — halcyon (consumer side)

Enforceable rules governing how this repo consumes ceyx-published artifacts.
MUST/NEVER are grep-verifiable; "how to verify" lines are the actual check.

## 1. One workflow per role

This repo has exactly two roles: `ci` (`ci.yml`, PR/push validation) and
`release` (`release.yml`, tag-triggered packaging). Both are thin wrappers
over `scripts/ci.py` / `scripts/build_apps.py`. A new workflow file outside
these two roles MUST carry a header comment
`# RATIONALE: <why this cannot extend ci.yml or release.yml>`.

Verify: `ls .github/workflows/*.yml` — only `ci.yml` and `release.yml`
expected; anything else needs the rationale header.

## 2. Naming SSOT is owned by ceyx, consumed verbatim here

Fetched asset names follow ceyx's `<component>-<platform>-<arch>[.<ext>]`
scheme (`x86_64` underscore, never `x86-64`), vocabulary defined in ceyx's
`native/deps/arch_map.toml`. `CEYX_FETCH_SPECS` in `scripts/build_apps.py`
MUST reference these exact stems — do not invent local aliases.

Verify: `grep -n 'x86-64' scripts/ceyx_release_pin.json` → zero hits. In
`scripts/build_apps.py`, scope the check to the ceyx `CEYX_FETCH_SPECS` table
and any string built into a fetch/asset URL — do not grep the whole file:
`build_apps.py:199-232` legitimately contains `x86-64`-style strings for
unrelated pre-existing Halide distribution names that are not ceyx asset
names. Correct check: `sed -n '/^CEYX_FETCH_SPECS/,/^}/p' scripts/build_apps.py
| grep -n 'x86-64'` → zero hits.

## 3. Ceyx's publish module is the only trusted producer

Assets are only trusted if they came from ceyx's single publish job
(`native/scripts/publish_release.py`) in the same release. This repo does not
call `gh release upload` against ceyx's releases and has no mechanism to do
so; it only reads.

## 4. `ceyx_release_pin.json` is the downstream authority; `artifacts.lock` cross-checks it

`scripts/ceyx_release_pin.json` remains the authority a human diff-reviews on
every bump. Its shape per entry is `{archive, sha256, libraries: [{member,
artifact, sha256}], ...}` plus a top-level `lock: {asset, sha256}` pinning
`artifacts.lock`'s own digest — one release publishes one `.tar.gz` per
component/platform (not loose per-file assets), so the pin covers the archive
digest, each extracted member's digest, and the lock file's own digest. The
fetched `artifacts.lock` is used to *cross-check* the pin's completeness and
hashes — not to replace it. A fetch that finds a pin entry missing from the
lock, or a hash mismatch between pin, lock, or an extracted member, MUST fail
the build rather than silently prefer one source.

Verify: the fetch/verify step in `build_apps.py` downloads `artifacts.lock`
alongside assets and diffs it against the pin before extraction; RC=0 only if
both agree.

## 5. Atomic groups stay atomic

The Windows trio (`dng_decoder_native.dll` + `heif.dll` + `libde265.dll`)
ships bundled inside one archive (`dng_decoder_native-windows-x86_64.tar.gz`)
because `dng_decoder_native.dll` dynamically imports the other two; this
repo's `CEYX_FETCH_SPECS` entry extracts all three from that one archive as
an `atomic_group` and MUST fail the build if any member is missing after
extraction — there is no partial-fetch case since one download brings all
three, but a partial-*extraction* (corrupt/truncated archive) MUST still be
caught by the member count assertion.

Verify: the Windows `CEYX_FETCH_SPECS` entry lists all three `libraries[]`
members from a single `archive` and documents an `atomic_group`; a count
assertion in `build_apps.py` guards the group size after extraction.

## 6. Hash-pinned consumption, never "latest"

Two things are pinned independently and both MUST be a reviewable committed
diff, never resolved automatically at build time:
- the ceyx source commit SHA — `ref:` in `ci.yml`/`release.yml` checkout steps;
- the asset bytes — per-asset `sha256` in `ceyx_release_pin.json`.

`--ceyx-release latest|<tag>` MAY be used to *regenerate* the pin file as a
proposed diff (it downloads, records real digests, and exits without
building — never builds unpinned); the committed pin (default `pinned` mode,
not "latest") is what an actual CI run fetches against. Prefer an explicit
tag over the bare `latest` flag when regenerating: GitHub's `/releases/latest`
API is a mutable pointer, not "the newest tag" — it was observed 2026-08-31
reporting `v0.1.5` while `v0.1.6` was already published and not a prerelease,
so `latest` can silently pin a stale release.

Verify: `grep -n 'ref:' .github/workflows/ci.yml .github/workflows/release.yml`
shows a fixed SHA, not a branch name or `HEAD`; the fetch path refuses a
sha256 mismatch (non-zero exit).

## 7. Ceyx ref bump procedure

Bumping the ceyx `ref` in `ci.yml`/`release.yml` is a separate, reviewable
commit from bumping `ceyx_release_pin.json`. Bump the ref only to a ceyx
`main` commit that has actually produced the release the pin points at (or
later); do not bump ref and pin to inconsistent points in ceyx history.

Verify: `git log -1 --format=%H` at the pinned `ref` is an ancestor-or-equal
of, or postdates, the commit that tagged the release named in the pin.

## 8. Triggers must match intent

`ci.yml` MUST run on `pull_request` against the default branch; `release.yml`
MUST be tag-triggered. Neither is a bootstrap-only `push: ci/**` gate.

Verify: `grep -A3 '^on:' .github/workflows/ci.yml .github/workflows/release.yml`.

## 9. Provenance for committed binaries

This repo does not commit third-party binary trees fetched from ceyx (they
are build-time artifacts, extracted then discarded/gitignored). No local
`PROVENANCE.md` obligation today; provenance for the bytes themselves lives in
ceyx's `native/third_party/*/PROVENANCE.md` and this repo's pin file records
which release/hash was consumed. If this repo ever commits a fetched or
vendored binary tree, that tree MUST gain its own `PROVENANCE.md` at the same
time — the exemption above applies only while nothing binary is committed.

## 10. Deletion requires a consumer audit, not a run count

Before removing a fetch spec, sha256 entry, or workflow step, grep this repo
for consumers of the resulting file (e.g. `plugin/**` paths that expect the
extracted `.so`/`.dll`), not just recent `gh run list` output — run history
expiry proves retention, not non-use.

Verify: PR description for any pin/fetch-spec removal links a repo-wide grep
for the removed asset's consumers.

## Deferred

A mechanical `workflow-lint` job (ceyx rule 10) has no counterpart here yet;
not implemented this round.
