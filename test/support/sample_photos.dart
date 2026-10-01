import 'dart:io';

/// Shared access to the real photo sample directories used by content-level
/// tests. Samples live in the sibling ceyx checkout, `../ceyx/image_samples`
/// (DNGs under `batch_run_samples/`), which is ABSENT on runners that do not
/// check ceyx out next to halcyon. Tests that depend on them
/// must skip themselves (rather than throw) when the samples are unavailable.
///
/// "Unavailable" means EITHER the sample directory is missing/empty, OR the
/// environment variable `HALCYON_NO_SAMPLES` is set (the override exists purely
/// so the absent-samples path can be verified locally without deleting or
/// renaming the real directory).
///
/// When `HALCYON_NO_SAMPLES` is set, [sampleDngDir]/[sampleJpgDir] additionally
/// point at a guaranteed-nonexistent path. This is deliberate: it makes a local
/// `HALCYON_NO_SAMPLES=1 flutter test` a FAITHFUL proxy for CI. The env flag
/// alone only changes the skip decision; it cannot hide the real files from a
/// test that lists the directory directly, so an UNGUARDED sample-dependent
/// test would still pass locally (files present) while throwing
/// PathNotFoundException on a CI runner (files absent). Redirecting the
/// directories closes that blind spot: any test that reaches for the samples
/// without a skip guard throws the same PathNotFoundException locally.
///
/// Usage:
/// ```dart
/// import '../../support/sample_photos.dart';
///
/// void main() {
///   group('...', () {
///     // ...
///   }, skip: samplePhotosSkipReason);
/// }
/// ```

bool _envDisablesSamplesValue = Platform.environment.containsKey(
  'HALCYON_NO_SAMPLES',
);
bool get _envDisablesSamples => _envDisablesSamplesValue;

// A path that does not exist, used only when HALCYON_NO_SAMPLES is set so that
// a direct listing throws exactly as a CI runner without the samples would.
const _absentDngDir = '/nonexistent/halcyon-no-samples/photo_samples/DNG';
const _absentJpgDir = '/nonexistent/halcyon-no-samples/photo_samples/JPG';

/// DNG sample directory: the 25 `batch_run_samples` DNGs, all with an embedded
/// preview (measured 2026-10-01 with `extractFullSizeEmbeddedJpeg`).
final Directory sampleDngDir = Directory(
  _envDisablesSamples
      ? _absentDngDir
      : '../ceyx/image_samples/batch_run_samples',
);

/// Root of the sample tree; holds `jpg_sample.jpg` and the no-preview DNGs.
final Directory sampleRootDir = Directory(
  _envDisablesSamples ? _absentJpgDir : '../ceyx/image_samples',
);

/// JPG sample directory (the tree root; `jpg_sample.jpg` is its only `.jpg`).
final Directory sampleJpgDir = sampleRootDir;

// Fixtures below were MEASURED on 2026-10-01 against the real files (probe:
// a scratch audit probe, output not retained), not guessed.

/// The DNG without any qualifying embedded JPEG (`extractFullSizeEmbeddedJpeg`
/// and `extractEmbeddedJpeg` both null; readOrientation 1), in [sampleRootDir].
/// `bayer_conc_a.dng` (9874332 bytes) is its no-preview sibling.
const kSampleNoPreviewDng = 'bayer_conc_b.dng';
const kSampleNoPreviewDngBytes = 13366744;
const kSampleNoPreviewDngs = ['bayer_conc_a.dng', 'bayer_conc_b.dng'];

/// A [sampleDngDir] DNG with orientation 1; largest preview 6000x4000, the
/// candidate `longEdge: 200` selects is 256x171 / 12922 bytes.
const kSamplePreviewDng = '2025-12-07-17-17-59.dng';

/// A [sampleDngDir] DNG with EXIF orientation 8 (largest preview 6000x4000).
const kSampleRotatedPreviewDng = '2025-12-07-17-16-07.dng';

/// The whole DNG corpus for "every sample DNG" loops: the [sampleDngDir] DNGs
/// (all with a preview) plus the [kSampleNoPreviewDngs] from [sampleRootDir].
/// 27 files, sorted within each part. Throws under `HALCYON_NO_SAMPLES` (the
/// directories are redirected to a nonexistent path), like a bare listing.
List<File> sampleDngFiles() => [
  ...(sampleDngDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.dng'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path))),
  for (final n in kSampleNoPreviewDngs) File('${sampleRootDir.path}/$n'),
];

/// Every [sampleDngDir] DNG; each carries a qualifying embedded preview.
const kSamplePreviewDngs = <String>[
  '2025-12-07-17-16-07.dng',
  '2025-12-07-17-16-28.dng',
  '2025-12-07-17-16-39.dng',
  '2025-12-07-17-17-03.dng',
  '2025-12-07-17-17-05.dng',
  '2025-12-07-17-17-59.dng',
  '2025-12-07-17-18-24.dng',
  '2025-12-07-17-18-27.dng',
  '2025-12-07-17-19-13.dng',
  '2025-12-07-17-20-17.dng',
  '2025-12-07-17-20-28.dng',
  '2025-12-07-17-20-33.dng',
  '2025-12-07-18-01-02.dng',
  '2025-12-07-19-08-42.dng',
  '2025-12-07-19-08-45.dng',
  '2025-12-07-19-08-51.dng',
  '2025-12-07-19-08-53.dng',
  '2025-12-07-19-10-23.dng',
  '2025-12-07-19-10-24.dng',
  '2025-12-07-20-24-08.dng',
  '2025-12-07-20-24-12.dng',
  '2025-12-07-20-25-36.dng',
  '2025-12-07-20-29-02.dng',
  '2025-12-07-20-29-06.dng',
  '2025-12-07-20-29-10.dng',
];

bool _dirHasFiles(Directory dir) {
  if (!dir.existsSync()) return false;
  return dir.listSync().whereType<File>().isNotEmpty;
}

/// True when the real photo samples can be read for this run.
bool get samplePhotosAvailable {
  if (_envDisablesSamples) return false;
  return _dirHasFiles(sampleDngDir);
}

/// Non-null skip reason when the samples are unavailable; null when present.
///
/// Pass directly to the `skip:` argument of `group`/`test`, e.g.
/// `group('...', () { ... }, skip: samplePhotosSkipReason);`
String? get samplePhotosSkipReason => samplePhotosAvailable
    ? null
    : 'Real photo samples unavailable '
          '(../ceyx/image_samples/batch_run_samples absent/empty or HALCYON_NO_SAMPLES set).';
