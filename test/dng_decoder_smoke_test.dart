import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/dng_decode_service.dart';

/// Round-3b smoke test: proves `decodeDngFull` really decodes a DNG that has
/// no embedded full-size JPEG preview, through the actual native dylib.
///
/// Uses plain `test()`, NOT `testWidgets()` — a `testWidgets` body runs in a
/// FakeAsync zone and awaiting a real native/isolate future hangs until
/// timeout (this cost a prior round two false diagnoses).
///
/// ponytail: the dylib-preload workaround below is test-only scaffolding
/// (dyld cannot resolve a bare leaf name cold under `flutter test`'s cwd;
/// see round-3b handover §8 fact list). Production resolves the dylib from
/// `<App>.app/Contents/Frameworks/`, where the `dng_processor_ffi` plugin pod
/// vendors it, via dng_bindings.dart's own search order — this file must never
/// leak that workaround into lib/.
void main() {
  test(
    'decodeDngFull decodes the vivo sample at full resolution',
    () async {
      final dylibPath = _resolveDngProcessorDylib();
      expect(
        File(dylibPath).existsSync(),
        isTrue,
        reason: 'dng_processor native dylib not found at $dylibPath. '
            'Build it in the flutter_dng_decoder repo first.',
      );
      // Preload via absolute path once; subsequent bare-leaf-name
      // DynamicLibrary.open calls made inside dng_bindings.dart (including
      // from the decodeOnWorker isolate) then resolve against this
      // already-loaded image (dlopen state is process-wide).
      DynamicLibrary.open(dylibPath);

      const samplePath =
          'local_data/photo_samples/DNG/IMG_20251112_092839.dng';
      expect(
        File(samplePath).existsSync(),
        isTrue,
        reason: 'Sample DNG not found at $samplePath',
      );

      final result = await decodeDngFull(samplePath);

      expect(result.width, 4080);
      expect(result.height, 3056);
      expect(result.rgba.length, 49873920);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// Resolves the vendored dylib via `.dart_tool/package_config.json`, without
/// hardcoding a dev machine path.
///
/// 2026-08-21 (D1): this used to point at `dng_processor`'s CMake build tree
/// (`native/build/`), which only exists on a machine that has built the native
/// target. It now points at the copy `dng_processor_ffi` vendors into host app
/// bundles — the same bytes that actually ship.
String _resolveDngProcessorDylib() {
  final configFile = File('.dart_tool/package_config.json');
  expect(
    configFile.existsSync(),
    isTrue,
    reason: '.dart_tool/package_config.json missing; run `flutter pub get`.',
  );

  final config = jsonDecode(configFile.readAsStringSync()) as Map;
  final packages = config['packages'] as List;
  final dngPackage = packages.cast<Map>().firstWhere(
        (p) => p['name'] == 'dng_processor_ffi',
        orElse: () => throw StateError(
          'dng_processor_ffi not found in package_config.json; '
          'check pubspec.yaml path dependency.',
        ),
      );

  final rootUri = dngPackage['rootUri'] as String;
  // rootUri is relative to the package_config.json file's own directory.
  final configDirUri = configFile.absolute.parent.uri;
  final pkgRootUri = configDirUri.resolve(rootUri);
  final pkgRoot = Directory.fromUri(pkgRootUri).path;

  return '$pkgRoot/macos/Libraries/libdng_decoder_native.dylib';
}
