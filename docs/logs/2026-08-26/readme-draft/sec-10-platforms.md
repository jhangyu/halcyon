## Platform support

Halcyon is a desktop application first. All six Flutter targets compile, but they are not
equivalent: the desktop targets are the ones the interface was designed for, the mobile
targets build and run without a touch-adapted layout, and three targets have no native
RAW decoder at all.

### Support matrix

| Target | Builds | Interface | Native RAW decode | System Trash | "Open With" from the file manager |
|---|---|---|---|---|---|
| macOS | Yes, arm64 only | Designed for this | Yes | Yes | Yes |
| Windows | Yes, on a Windows host | Desktop layout, less exercised | Yes | Yes, via `IFileOperation` | No |
| Linux | Yes, on a Linux host | Desktop layout, less exercised | No | No — falls back to in-folder recycle mode | No |
| Android | Yes | Compiles; not adapted for touch | Yes | No | No |
| iOS | Yes, unsigned by default | Compiles; not adapted for touch | No | No | No |
| Web | Yes | Compiles; not adapted | No | No | No |

<!-- evidence: scripts/build_apps.py:249-266 (TARGET_HELP / ALL_TARGETS) -->
<!-- evidence: scripts/build_apps.py:265-270 (NATIVE_SPECS covers macos, windows, android only; the comment names web, ios and linux as having no native decoder) -->
<!-- evidence: macos/Runner/AppDelegate.swift:23,42 (exactly two channels: halcyon/trash, halcyon/open_with) -->

### What the gaps mean in practice

**No native decoder on Linux, iOS and web.** The Ceyx decoding library is built for macOS,
Windows and Android only. On the other three targets the full-RAW-decode path does not
exist, so a RAW file is viewable only when its container carries an embedded JPEG preview
large enough to use. Most modern cameras write such a preview, so browsing usually still
works — but a file without one cannot be displayed on those platforms.

<!-- evidence: scripts/build_apps.py:265-270 -->

**Two native bridges, unevenly implemented.** macOS registers both `MethodChannel`
bridges in `macos/Runner/AppDelegate.swift`: `halcyon/trash` for moving files to the
system Trash, and `halcyon/open_with` for receiving file paths when a photo is opened
through the Finder. Windows implements `halcyon/trash` on top of the Win32
`IFileOperation` API, so the system Recycle Bin works there too. Android, iOS, Linux and
web have neither bridge, and delete on those platforms uses the in-folder recycle mode —
a complete feature, not a degraded one.

<!-- evidence: macos/Runner/AppDelegate.swift:12,23,42 -->
<!-- evidence: windows/runner/halcyon_channels.cpp:51, windows/runner/halcyon_trash.cpp:1, windows/runner/halcyon_native.h:53 -->

**macOS builds are arm64 only,** because the vendored decoder library is arm64 only. An
Intel Mac build would need an x86_64 or universal decoder library first.

<!-- evidence: CLAUDE.md, scripts/build_apps.py --macos-arch option at scripts/build_apps.py:1636 -->

**Image loading itself is pure Dart on every platform.** There is no native thumbnail
channel; a single Dart entry point produces image bytes everywhere. Platform divergence is
confined to the two macOS bridges above.

<!-- evidence: lib/services/image_pipeline/dart_image_loader.dart, memory.md AD-020 -->
