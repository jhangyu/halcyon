# Third-Party Licenses

This document covers what Halcyon itself ships: the Flutter application code in this
repository, the Dart packages it depends on, and — transitively, through the `ceyx`
path dependency — the native RAW decoding stack that Ceyx compiles and Halcyon bundles
into its app binary on every platform. This is an index, not a substitute for the full
license texts it points to; those texts live with each component (in the pub cache for
Dart packages, and in the Ceyx repository for the native stack).

This document is modelled on and reads as a pair with
`/Users/jhangyu/project/ceyx/docs/legal/THIRD_PARTY_LICENSES.md` (Ceyx's own
third-party attribution). Where Halcyon ships something Ceyx already documents, this
file attributes it as *transitive* and reproduces Ceyx's own license identification
rather than re-deriving it independently.

## Halcyon's own license status

**Halcyon declares no license.** There is no `LICENSE` file at the repository root and
`pubspec.yaml` has no `license:` field.
<!-- evidence: pubspec.yaml:1-19 -->

This is an open item independent of everything else in this document — see
"Open questions" below.

## Direct Dart package dependencies (declared in `pubspec.yaml`)

Licenses below were read directly from each package's `LICENSE` file in the local pub
cache (`~/.pub-cache/hosted/pub.dev/<package>-<version>/LICENSE`), at the exact version
pinned in `pubspec.lock`, not inferred from the package's typical ecosystem convention.

| Package | Version | License | Source of identification |
|---|---|---|---|
| `cupertino_icons` | 1.0.8 | MIT | pub cache LICENSE file |
| `provider` | 6.1.5+1 | MIT | pub cache LICENSE file |
| `file_selector` | 1.1.0 | BSD-3-Clause | pub cache LICENSE file ("Copyright 2013 The Flutter Authors", 3-clause redistribution text) |
| `path` | 1.9.1 | BSD-3-Clause | pub cache LICENSE file ("Copyright 2014, the Dart project authors", 3-clause redistribution text) |
| `path_provider` | 2.1.5 | BSD-3-Clause | pub cache LICENSE file ("Copyright 2013 The Flutter Authors") |
| `shared_preferences` | 2.5.4 | BSD-3-Clause | pub cache LICENSE file ("Copyright 2013 The Flutter Authors") |
| `exif` | 3.3.0 | MIT | pub cache LICENSE file |
| `image` | 4.9.2 | MIT | pub cache LICENSE file (package also ships a separate `LICENSE-other.md` for a bundled sub-component; not inspected in this pass — see open questions) |
| `desktop_drop` | 0.8.0 | Apache-2.0 | pub cache LICENSE file |
| `flutter_launcher_icons` (dev) | 0.14.4 | MIT | pub cache LICENSE file |
| `flutter_lints` (dev) | 5.0.0 | BSD-3-Clause | pub cache LICENSE file ("Copyright 2013 The Flutter Authors") |
| `ceyx` | 0.0.1 (path dependency) | Not a pub.dev license — see "Transitive: native decoding stack" below | `pubspec.lock:36-42` (path source, not hosted) |
<!-- evidence: pubspec.lock:1-598 -->
<!-- evidence: ~/.pub-cache/hosted/pub.dev/{cupertino_icons-1.0.8,provider-6.1.5+1,file_selector-1.1.0,path-1.9.1,path_provider-2.1.5,shared_preferences-2.5.4,exif-3.3.0,image-4.9.2,desktop_drop-0.8.0,flutter_launcher_icons-0.14.4,flutter_lints-5.0.0}/LICENSE (read directly) -->

The Flutter and Dart SDKs themselves (`flutter`, `flutter_test`, `sky_engine`,
`flutter_web_plugins` in `pubspec.lock`, all `source: sdk`) are not pub.dev packages;
they ship under the Flutter SDK's own license, BSD-3-Clause ("Copyright 2014 The
Flutter Authors"), read from the local Flutter SDK checkout's `LICENSE` file rather
than a pub cache entry.
<!-- evidence: pubspec.lock:211-215,232-241,482-486 -->

**Transitive Dart package dependencies** (everything in `pubspec.lock` marked
`dependency: transitive` — roughly 45 packages such as `archive`, `ffi`, `collection`,
`meta`, `http`, the platform-interface packages, etc.) were not individually resolved
in this pass. They are pulled in by the direct dependencies above and by the Flutter
SDK itself, and the large majority of the Flutter/Dart package ecosystem uses
BSD-3-Clause or MIT — but that is an ecosystem convention, not a per-package
verification, and is explicitly **not** asserted as a license identification here. See
"Open questions."

## Transitive: native decoding stack (arrives via the `ceyx` path dependency)

Halcyon does not vendor or build any native RAW/DNG decoding code itself. It consumes
Ceyx as a `path:` dependency (`ceyx: path: ../ceyx/plugin`,
<!-- evidence: pubspec.yaml:46-47 -->
`ceyx` pinned as a `path` source in `pubspec.lock:36-42`) and Ceyx's Flutter plugin
packaging bundles Ceyx's compiled native library
(`libdng_decoder_native.dylib` on macOS, the corresponding `.so` on Android, the `.dll`
on Windows) into the Halcyon app bundle at build time. Every component below is
reproduced from Ceyx's own `docs/legal/THIRD_PARTY_LICENSES.md`, not re-derived, because
it is Ceyx's build that compiles and links these components — Halcyon receives the
already-built binary.

| Component | License | Linkage (per Ceyx's document) |
|---|---|---|
| Adobe DNG SDK | Adobe DNG SDK License Agreement (royalty-free use, reproduction and distribution; see the agreement for restrictions) | Compiled from source into the native library |
| Halide | MIT | Statically linked AOT-compiled GPU-kernel runtime |
| LibRaw | Dual-licensed LGPL-2.1 / CDDL-1.0; Ceyx elects LGPL-2.1 | Statically linked into the native library when the generic-RAW route is enabled (Ceyx's default) |
| RawSpeed3 (bundled RawSpeed) | LGPL-2.1 | Compiled as a static library, linked only into the LibRaw target |
| pugixml | MIT | Bundled by RawSpeed3 at build-configure time |
| LibRaw-cmake | MIT | Build-time CMake overlay only; contributes no shipped source |
| libjpeg-turbo | IJG License + Modified 3-clause BSD License; SIMD sources zlib-licensed | Statically linked on every platform |
| zlib | zlib License | Dynamically linked against the platform's system zlib on macOS/Android; statically built from source on Windows |
| x3f-tools (Foveon X3F support, bundled inside LibRaw) | BSD-3-Clause, as redistributed by LibRaw | Compiled in; live in the shipped binary since LibRaw's `ENABLE_X3FTOOLS` is on |
<!-- evidence: /Users/jhangyu/project/ceyx/docs/legal/THIRD_PARTY_LICENSES.md:13-129 (full document, reproduced verbatim per-component; read in full before writing this table) -->

## The LGPL-2.1 obligation, stated plainly

LibRaw and RawSpeed3 are both licensed LGPL-2.1 and are both **statically** linked into
the native library that Ceyx builds and that Halcyon bundles into its own app binary.
Static linking under LGPL-2.1 creates an obligation toward anyone who receives that
built binary: the recipient must be given either relinkable object files or the
complete corresponding source for the LGPL-licensed components, so that they could, in
principle, relink the library against a modified version of LibRaw/RawSpeed3.

**How Ceyx says this obligation is satisfied on its side:** Ceyx's document states that
the full LibRaw source at the pinned revision is retained (untracked in git, fetched by
`native/scripts/fetch_libraw_dist.sh`), with provenance recorded in
`native/third_party/libraw/PROVENANCE.md`, and that "the source offer is this
repository plus that script." RawSpeed3 is stated to receive "the same static-linking
source-offer treatment as LibRaw."
<!-- evidence: /Users/jhangyu/project/ceyx/docs/legal/THIRD_PARTY_LICENSES.md:39-45,59-60 -->

**Open question — unresolved, requires legal review, not answered here:** When Halcyon
is distributed as a built application (for example, a packaged `.app`, `.apk`, or
Windows installer produced by `scripts/build_apps.py`), does Ceyx's source offer — "the
Ceyx repository plus its fetch script" — extend to satisfy the LGPL-2.1 obligation
toward *Halcyon's* recipients, who receive the Halcyon binary and may have no reason to
know the Ceyx repository exists or is a sibling checkout at build time? Or does
distributing a Halcyon build that bundles this statically-linked LGPL code create an
independent source-offer obligation that Halcyon's own release process must carry
(for example, publishing its own reference to the pinned LibRaw/RawSpeed3 revisions and
retrieval method, rather than relying on a reader finding Ceyx's documentation)? This
question needs a legal determination specific to how Halcyon is actually distributed to
end users, not an inference from the code or from Ceyx's document.

## Open questions

1. **The LGPL-2.1 source-offer question above** — does a distributed Halcyon build
   satisfy its LGPL-2.1 obligation for LibRaw/RawSpeed3 by reference to the Ceyx
   repository, or does it need an independent source offer of its own? Requires legal
   review.
2. **Halcyon declares no license of its own** — no `LICENSE` file, no `license:` field
   in `pubspec.yaml`. This is a separate, independent open item from the LGPL question:
   it concerns what terms (if any) govern *Halcyon's own source code*, not the
   third-party components it bundles. Needs a decision from whoever is authorized to
   set Halcyon's license, not an inference from this document.
3. **~45 transitive Dart package dependencies were not individually license-verified**
   in this pass (see the note under "Direct Dart package dependencies" above). If a
   fully exhaustive Dart-dependency license audit is required, each transitive package
   in `pubspec.lock` needs the same per-package pub-cache verification applied to the
   11 direct dependencies here.
4. **`image` 4.9.2 ships a second license file** (`LICENSE-other.md` alongside
   `LICENSE`) that was not opened or attributed in this pass — it may cover a bundled
   sub-component with different terms. Needs inspection before this table is treated as
   complete for that package.
