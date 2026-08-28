import 'dart:io';

/// Shared access to the real photo sample directories used by content-level
/// tests. Samples live under `local_data/photo_samples/{DNG,JPG}/`, which is
/// `.gitignore`d and therefore ABSENT on CI runners. Tests that depend on them
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

bool _envDisablesSamplesValue =
    Platform.environment.containsKey('HALCYON_NO_SAMPLES');
bool get _envDisablesSamples => _envDisablesSamplesValue;

// A path that does not exist, used only when HALCYON_NO_SAMPLES is set so that
// a direct listing throws exactly as a CI runner without the samples would.
const _absentDngDir = '/nonexistent/halcyon-no-samples/photo_samples/DNG';
const _absentJpgDir = '/nonexistent/halcyon-no-samples/photo_samples/JPG';

/// DNG sample directory (path as used across the test suite today).
final Directory sampleDngDir = Directory(
  _envDisablesSamples ? _absentDngDir : 'local_data/photo_samples/DNG',
);

/// JPG sample directory (path as used across the test suite today).
final Directory sampleJpgDir = Directory(
  _envDisablesSamples ? _absentJpgDir : 'local_data/photo_samples/JPG',
);

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
        '(local_data/photo_samples absent/empty or HALCYON_NO_SAMPLES set).';
