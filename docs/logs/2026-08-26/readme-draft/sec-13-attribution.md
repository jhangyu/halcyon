## Third-party attribution

Halcyon's own source in this repository carries no declared license — there is no
`LICENSE` file at the repository root and no `license:` field in `pubspec.yaml`.
<!-- evidence: pubspec.yaml:1-19 -->
What Halcyon *does* bundle is a set of Dart packages declared in `pubspec.yaml`, plus —
transitively, through the sister project Ceyx — the native RAW/DNG decoding stack that
Ceyx compiles and Halcyon ships inside its own app binary on every platform.

| Component | License | Notes |
|---|---|---|
| Direct Dart dependencies (`provider`, `path`, `image`, `exif`, `desktop_drop`, etc.) | Mostly MIT / BSD-3-Clause / Apache-2.0 | Per-package identification in the linked document; not an ecosystem assumption |
| Adobe DNG SDK | Adobe DNG SDK License Agreement | Transitive, via `ceyx` |
| LibRaw, RawSpeed3 | LGPL-2.1 (statically linked) | Transitive, via `ceyx`; carries a source-offer obligation — see open question below |
| Halide, pugixml, LibRaw-cmake | MIT | Transitive, via `ceyx` |
| libjpeg-turbo, zlib, x3f-tools | Permissive (IJG/BSD/zlib/BSD-3-Clause) | Transitive, via `ceyx` |

The full accounting — exact versions, per-package license text sources, and the
reasoning behind each attribution — lives in
[`docs/legal/THIRD_PARTY_LICENSES.md`](docs/legal/THIRD_PARTY_LICENSES.md).

One item there is not a settled fact and is stated as an open legal question rather
than resolved here: LibRaw and RawSpeed3 are LGPL-2.1 and statically linked into the
native library Halcyon ships, which obligates making source or relinkable objects
available to recipients of the binary. Whether Ceyx's own source offer already covers
a distributed Halcyon build, or whether Halcyon's release process needs an independent
one, has not been determined and needs legal review before Halcyon is distributed
outside this development environment.
