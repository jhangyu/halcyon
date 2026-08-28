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

/// DNG sample directory (path as used across the test suite today).
final Directory sampleDngDir = Directory('local_data/photo_samples/DNG');

/// JPG sample directory (path as used across the test suite today).
final Directory sampleJpgDir = Directory('local_data/photo_samples/JPG');

bool get _envDisablesSamples =>
    Platform.environment.containsKey('HALCYON_NO_SAMPLES');

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
