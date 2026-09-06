import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_normalizer.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_service.dart';
import '../../support/sample_photos.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:halcyon_flutter/services/image_pipeline/raw_pixels_image.dart';
import '../../support/preload_fixtures.dart';

// --- top-level helpers from payload_normalizer_test.dart ---
Uint8List _bytes(int length, {int fill = 7}) =>
    Uint8List.fromList(List<int>.filled(length, fill));

({Uint8List rgba, int width, int height}) _rgba(int w, int h) =>
    (rgba: Uint8List(w * h * 4), width: w, height: h);

// --- top-level helpers from dng_decoder_smoke_test.dart ---
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
/// `<App>.app/Contents/Frameworks/`, where the `ceyx` plugin pod
/// vendors it, via dng_bindings.dart's own search order — this file must never
/// leak that workaround into lib/.

// --- top-level helpers from raw_coverage_wiring_test.dart ---
/// Contract: docs/logs/2026-08-26/raw-support-contract.md
///
/// T4 scope: full-decoder wiring through the preload controller / app_state
/// side of the pipeline. `image_source_types.dart`/`dart_image_loader.dart`
/// are owned by other members (T2/T3); these tests drive the CONTROLLER
/// through the same public seam the pre-existing suite uses (see
/// photo_source_test.dart's design note) rather than asserting on those
/// files' internals.

// --- top-level helpers from raw_pixels_image_test.dart ---
// Plain test(), never testWidgets(): decoding awaits a real engine future
// (ui.decodeImageFromPixels), which hangs forever inside testWidgets'
// FakeAsync zone.

void main() {
  group('payload_normalizer_test.dart', () {
      setUp(() {
        resetNormalizeCounters();
        resetReencodeCounters();
      });

      // TC-413
      test('input at or under the passthrough size is returned untouched',
          () async {
        final input = _bytes(kNormalizePassthroughMaxBytes);
        var decodes = 0;
        final out = await normalizeEncodedPayload(
          encoded: input,
          encoder: (rgba, {required width, required height, required quality}) async =>
              _bytes(10),
          decodeToRgba: (bytes) async {
            decodes++;
            return _rgba(4, 4);
          },
        );
        expect(out, isA<EncodedPayload>());
        expect(identical((out as EncodedPayload).bytes, input), isTrue);
        expect(decodes, 0);
        expect(normalizeFallbacks, 0);
        expect(reencodeFallbacks, 0);
      });

      // TC-414
      test('large input is decoded and re-encoded at quality 70', () async {
        final input = _bytes(kNormalizePassthroughMaxBytes + 1);
        final calls = <({int width, int height, int quality})>[];
        final out = await normalizeEncodedPayload(
          encoded: input,
          encoder: (rgba, {required width, required height, required quality}) async {
            calls.add((width: width, height: height, quality: quality));
            return _bytes(64, fill: 3);
          },
          decodeToRgba: (bytes) async => _rgba(80, 60),
        );
        expect(calls, <({int width, int height, int quality})>[
          (width: 80, height: 60, quality: 70),
        ]);
        expect((out as EncodedPayload).bytes.length, 64);
        expect(normalizeFallbacks, 0);
        expect(reencodeFallbacks, 0);
      });

      // TC-415 (amendment E-M1: delegates to reencodePayload, shared counter)
      test('undecodable input keeps the original bytes and counts a fallback',
          () async {
        final input = _bytes(kNormalizePassthroughMaxBytes + 1);
        var encoderCalls = 0;
        final out = await normalizeEncodedPayload(
          encoded: input,
          encoder: (rgba, {required width, required height, required quality}) async {
            encoderCalls++;
            return _bytes(4);
          },
          decodeToRgba: (bytes) async => null,
        );
        expect(identical((out as EncodedPayload).bytes, input), isTrue);
        expect(encoderCalls, 0);
        expect(reencodeFallbacks, 1);
        expect(normalizeFallbacks, 0);
      });

      // TC-416 (amendment E-M1: delegates to reencodePayload, shared counter)
      test('a throwing encoder keeps the original bytes', () async {
        final input = _bytes(kNormalizePassthroughMaxBytes + 1);
        final out = await normalizeEncodedPayload(
          encoded: input,
          encoder: (rgba, {required width, required height, required quality}) async {
            throw StateError('boom');
          },
          decodeToRgba: (bytes) async => _rgba(80, 60),
        );
        expect(identical((out as EncodedPayload).bytes, input), isTrue);
        expect(reencodeFallbacks, 1);
        expect(normalizeFallbacks, 0);
      });

      // TC-417 (normalisation-specific refusal, its own counter)
      test('an encoder output larger than the input is discarded', () async {
        final input = _bytes(kNormalizePassthroughMaxBytes + 1);
        final out = await normalizeEncodedPayload(
          encoded: input,
          encoder: (rgba, {required width, required height, required quality}) async =>
              _bytes(input.length + 1),
          decodeToRgba: (bytes) async => _rgba(80, 60),
        );
        expect(identical((out as EncodedPayload).bytes, input), isTrue);
        expect(normalizeFallbacks, 1);
        expect(reencodeFallbacks, 0);
      });

      // TC-418 (amendment E-M1: delegates to reencodePayload, shared counter)
      test('an rgba buffer disagreeing with its dimensions never reaches the '
          'encoder', () async {
        final input = _bytes(kNormalizePassthroughMaxBytes + 1);
        var encoderCalls = 0;
        final out = await normalizeEncodedPayload(
          encoded: input,
          encoder: (rgba, {required width, required height, required quality}) async {
            encoderCalls++;
            return _bytes(4);
          },
          decodeToRgba: (bytes) async => (rgba: Uint8List(8), width: 80, height: 60),
        );
        expect(identical((out as EncodedPayload).bytes, input), isTrue);
        expect(encoderCalls, 0);
        expect(reencodeFallbacks, 1);
        expect(normalizeFallbacks, 0);
      });

      // TC-419 (amendment E-M3: gate is an explicit parameter, own instance)
      test('the gate bounds how many normalisations decode at once', () async {
        final gate = NormalizeGate(width: 2);
        var live = 0;
        var maxLive = 0;
        final completers = <Completer<void>>[];
        final futures = <Future<SourcePayload>>[];
        for (var i = 0; i < 5; i++) {
          final completer = Completer<void>();
          completers.add(completer);
          futures.add(
            normalizeEncodedPayload(
              encoded: _bytes(kNormalizePassthroughMaxBytes + 1),
              encoder:
                  (rgba, {required width, required height, required quality}) async =>
                      _bytes(4),
              decodeToRgba: (bytes) async {
                live++;
                maxLive = live > maxLive ? live : maxLive;
                await completer.future;
                live--;
                return _rgba(4, 4);
              },
              gate: gate,
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);
        expect(maxLive, 2);
        for (final c in completers) {
          c.complete();
          await Future<void>.delayed(Duration.zero);
        }
        await Future.wait(futures);
        expect(maxLive, 2);
      });

  });

  group('dng_decoder_smoke_test.dart', () {
      test(
        'decodeDngFull decodes the vivo sample at full resolution',
        () async {
          final dylibPath = _resolveDngProcessorDylib();
          expect(
            File(dylibPath).existsSync(),
            isTrue,
            reason: 'ceyx native dylib not found at $dylibPath. '
                'Build it in the flutter_dng_decoder repo first.',
          );
          // Preload via absolute path once; subsequent bare-leaf-name
          // DynamicLibrary.open calls made inside dng_bindings.dart (including
          // from the decodeOnWorker isolate) then resolve against this
          // already-loaded image (dlopen state is process-wide).
          DynamicLibrary.open(dylibPath);

          final samplePath =
              '${sampleDngDir.path}/IMG_20251112_092839.dng';
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
        skip: samplePhotosSkipReason,
      );

  });

  group('raw_coverage_wiring_test.dart', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      test(
        'D2: a browse-only RAW (.cr2) that has no embedded preview stays a '
        'preview-only permanent miss -- it never reaches the full decoder',
        () async {
          // Simulates what the generalised dart_image_loader.dart reports for a
          // browse-only extension with no embedded preview: a plain
          // NativeImageFailure, NEVER NativeImageNeedsRawDecode, because D2
          // formats have no decode route at all (contract: "D2 -- formats the
          // engine cannot decode ... stay browsable via embedded preview only").
          var decoderCalls = 0;
          final controller = ImagePreloadController(
            imageLoader: (path, {required purpose, int? targetLongEdge}) async {
              return const NativeImageFailure(
                'RAW_NO_EMBEDDED_PREVIEW',
                'no embedded preview and no decoder for this format',
              );
            },
            dngDecoder: (path) async {
              decoderCalls++;
              throw StateError(
                'the decoder must never be invoked for a D2 browse-only RAW',
              );
            },
          );
          addTearDown(controller.dispose);

          final items = [
            PhotoItem(id: 'cr2-1', files: [File('/tmp/cr2-1.cr2')]),
          ];

          await controller.preloadImages(
            items: items,
            selectedItemId: 'cr2-1',
            notifyLoaded: () {},
          );

          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (!controller.hasFailed('cr2-1')) {
            if (DateTime.now().isAfter(deadline)) {
              fail('timed out waiting for the permanent-miss pass');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }

          expect(controller.imageBytesFor('cr2-1'), isNull);
          expect(controller.hasFailed('cr2-1'), isTrue);
          expect(
            decoderCalls,
            0,
            reason:
                'D2 browse-only formats have no decode route; the decoder must '
                'stay untouched',
          );
        },
      );

      test(
        'AC3: NativeImageResult has exactly three variants, proven by an '
        'exhaustive switch with no default case (a fourth variant fails to '
        'compile here, not just at runtime)',
        () {
          String classify(NativeImageResult r) => switch (r) {
            NativeImageBytes() => 'bytes',
            NativeImageNeedsRawDecode() => 'needs_raw_decode',
            NativeImageFailure() => 'failure',
          };

          expect(
            classify(NativeImageBytes(Uint8List.fromList([1, 2, 3]))),
            'bytes',
          );
          expect(
            classify(const NativeImageNeedsRawDecode(exifOrientation: 1)),
            'needs_raw_decode',
          );
          expect(
            classify(const NativeImageFailure('X', 'y')),
            'failure',
          );
        },
      );

      test(
        'a DngFullDecoder fake wired through the controller '
        'reaches an engine-decodable non-DNG RAW when the loader signals '
        'NeedsRawDecode -- proves the full-size path is format-agnostic once the '
        'loader routes correctly (photo_source.dart already dispatches '
        'NativeImageNeedsRawDecode to dngDecoder regardless of extension; the '
        'remaining gate lives in dart_image_loader.dart, owned by T2)',
        () async {
          var decodedPath = '';
          final controller = ImagePreloadController(
            imageLoader: (path, {required purpose, int? targetLongEdge}) async {
              return const NativeImageNeedsRawDecode(exifOrientation: 1);
            },
            dngDecoder: (path) async {
              decodedPath = path;
              // Alpha must be opaque (0xFF): decoded_rgba_image_provider.dart's
              // debug-only identity short-circuit asserts sampled alpha is
              // opaque. Same repair as commits 253b89f / d43c2a1.
              final rgba = Uint8List(4 * 2 * 2);
              for (var i = 3; i < rgba.length; i += 4) {
                rgba[i] = 0xFF;
              }
              return DecodedRgba(
                rgba: rgba,
                width: 2,
                height: 2,
              );
            },
          );
          addTearDown(controller.dispose);

          final items = [
            PhotoItem(id: 'rw2-1', files: [File('/tmp/rw2-1.rw2')]),
          ];

          await controller.preloadImages(
            items: items,
            selectedItemId: 'rw2-1',
            notifyLoaded: () {},
          );

          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (controller.imageBytesFor('rw2-1') == null &&
              controller.payloadFor('rw2-1') == null) {
            if (DateTime.now().isAfter(deadline)) {
              fail('timed out waiting for the RAW decode pass');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }

          expect(decodedPath, '/tmp/rw2-1.rw2');
        },
      );

      test(
        'AC5 D3: an engine-decodable RAW with no configured native decoder '
        '(a platform with no native library) is a permanent miss carrying the '
        'D3 no-native-decoder code -- distinct from a decoder that exists but '
        'throws',
        () async {
          final controller = ImagePreloadController(
            imageLoader: (path, {required purpose, int? targetLongEdge}) async {
              return const NativeImageNeedsRawDecode(exifOrientation: 1);
            },
            dngDecoder: null,
          );
          addTearDown(controller.dispose);

          final items = [
            PhotoItem(id: 'arw-1', files: [File('/tmp/arw-1.arw')]),
          ];

          await controller.preloadImages(
            items: items,
            selectedItemId: 'arw-1',
            notifyLoaded: () {},
          );

          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (!controller.hasFailed('arw-1')) {
            if (DateTime.now().isAfter(deadline)) {
              fail('timed out waiting for the permanent-miss pass');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }

          expect(controller.hasFailed('arw-1'), isTrue);
          expect(controller.isNoNativeDecoder('arw-1'), isTrue);
          expect(
            controller.noNativeDecoderCodeFor('arw-1'),
            kNoNativeDecoderCode,
          );
        },
      );

      test(
        'AC5 D3 negative: a THROWING decoder (decoder exists but failed) is a '
        'permanent miss WITHOUT the D3 no-native-decoder code -- not conflated '
        'with the no-decoder-on-this-platform state',
        () async {
          final controller = ImagePreloadController(
            imageLoader: (path, {required purpose, int? targetLongEdge}) async {
              return const NativeImageNeedsRawDecode(exifOrientation: 1);
            },
            dngDecoder: (path) async => throw StateError('native decode failed'),
          );
          addTearDown(controller.dispose);

          final items = [
            PhotoItem(id: 'arw-2', files: [File('/tmp/arw-2.arw')]),
          ];

          await controller.preloadImages(
            items: items,
            selectedItemId: 'arw-2',
            notifyLoaded: () {},
          );

          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (!controller.hasFailed('arw-2')) {
            if (DateTime.now().isAfter(deadline)) {
              fail('timed out waiting for the permanent-miss pass');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }

          expect(controller.hasFailed('arw-2'), isTrue);
          expect(
            controller.isNoNativeDecoder('arw-2'),
            isFalse,
            reason:
                'a throwing decoder is a genuine decode failure, not "no '
                'decoder on this platform" -- conflating them would hide a real '
                'bug behind a platform-support message',
          );
          expect(controller.noNativeDecoderCodeFor('arw-2'), isNull);
        },
      );

      test(
        'PhotoSource.load: decoder == null carries kNoNativeDecoderCode directly '
        'on SourceOutcome.failureCode (unit-level proof, below the controller '
        'seam)',
        () async {
          final source = PhotoSource(
            loader: (path, {required purpose, int? targetLongEdge}) async =>
                const NativeImageNeedsRawDecode(exifOrientation: 1),
            dngDecoder: null,
          );

          final outcome = await source.load(
            '/tmp/IMG_0000.arw',
            longEdge: 2800,
            allowExpensive: true,
          );

          expect(outcome.payload, isNull);
          expect(outcome.deferred, isFalse);
          expect(outcome.failureCode, kNoNativeDecoderCode);
        },
      );

      test(
        'PhotoSource.load: every other outcome (bytes, throwing decoder, '
        'NativeImageFailure) carries a null failureCode -- the field must not '
        'leak into unrelated paths',
        () async {
          final bytesSource = PhotoSource(
            loader: (path, {required purpose, int? targetLongEdge}) async =>
                NativeImageBytes(Uint8List.fromList([1, 2, 3])),
          );
          final bytesOutcome = await bytesSource.load(
            '/tmp/a.jpg',
            longEdge: 2800,
          );
          expect(bytesOutcome.failureCode, isNull);

          final throwingSource = PhotoSource(
            loader: (path, {required purpose, int? targetLongEdge}) async =>
                const NativeImageNeedsRawDecode(exifOrientation: 1),
            dngDecoder: (path) async => throw StateError('decode failed'),
          );
          final throwingOutcome = await throwingSource.load(
            '/tmp/b.arw',
            longEdge: 2800,
          );
          expect(throwingOutcome.failureCode, isNull);

          final failureSource = PhotoSource(
            loader: (path, {required purpose, int? targetLongEdge}) async =>
                const NativeImageFailure('UNREADABLE', 'corrupt'),
          );
          final failureOutcome = await failureSource.load(
            '/tmp/c.cr2',
            longEdge: 2800,
          );
          expect(failureOutcome.failureCode, isNull);
        },
      );

      // RETIRED (2026-08-30, plan Task 6): 'D2 sidebar fix: a browse-only RAW
      // (.cr2) never invokes the sized sidebar decoder'. The sized sidebar decoder
      // is deleted, so the gate it asserted on (isDecodablePath vs isRawPath) no
      // longer exists on this path. The D2 ruling itself is still enforced -- by
      // PhotoSource, covered by this file's failureCode tests above.

  });

  group('raw_pixels_image_test.dart', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      setUp(clearImageCacheSetUp);

      PixelPayload payloadOf(Uint8List rgba) =>
          PixelPayload(rgba: rgba, width: 2, height: 2);

      Uint8List freshPixels() =>
          Uint8List.fromList(List<int>.generate(2 * 2 * 4, (i) => i));

      Future<ui.Image> resolveOnce(ImageProvider provider) {
        final completer = Completer<ui.Image>();
        final stream = provider.resolve(const ImageConfiguration());
        late ImageStreamListener listener;
        listener = ImageStreamListener((info, _) {
          stream.removeListener(listener);
          completer.complete(info.image);
        }, onError: (error, _) {
          stream.removeListener(listener);
          completer.completeError(error);
        });
        stream.addListener(listener);
        return completer.future;
      }

      group('RawPixelsImage (I1: buffer identity IS the cache key)', () {
        // THE KILLER. Two payloads with byte-IDENTICAL content but separate
        // buffers must be DIFFERENT cache keys. Swapping the identity check for
        // value equality (listEquals, or hashing the bytes) passes every "same
        // buffer hits the cache" assertion and fails only here -- and that mutant
        // is exactly round-2 BLOCKER 1 reborn for pixels: an item that left the
        // window and was re-decoded would resolve to the ImageCache entry of its
        // OWN superseded pixels.
        test('TC-066 equal CONTENT in a different buffer is a different key', () {
          final first = freshPixels();
          final second = freshPixels();
          expect(first, second, reason: 'sanity: the two buffers are equal by '
              'value, so only identity can tell them apart');
          expect(identical(first, second), isFalse);

          expect(
            RawPixelsImage(payloadOf(first)) == RawPixelsImage(payloadOf(second)),
            isFalse,
            reason: 'value equality here silently resurrects the ImageCache entry '
                'of pixels the item no longer owns',
          );
          expect(
            RawPixelsImage(payloadOf(first)) == RawPixelsImage(payloadOf(first)),
            isTrue,
            reason: 'the SAME buffer must be the same key, or every navigation '
                'costs a duplicate decode',
          );
        });

        test('TC-067 resolving the same buffer twice decodes once', () async {
          final rgba = freshPixels();
          final image = await resolveOnce(RawPixelsImage(payloadOf(rgba)));
          expect(image.width, 2);

          final key = await RawPixelsImage(
            payloadOf(rgba),
          ).obtainKey(const ImageConfiguration());
          expect(
            PaintingBinding.instance.imageCache.containsKey(key),
            isTrue,
            reason: 'a second provider over the same buffer must land on the '
                'existing entry',
          );
          expect(PaintingBinding.instance.imageCache.currentSize, 1);
        });

        // The successor to the deleted DecodedRgbaImageProvider ownership group:
        // there is no master handle to keep alive, so eviction is allowed to
        // dispose what it holds and NOTHING outside the cache is affected.
        test('TC-068 eviction disposes the cache\'s own image and touches nothing '
            'the pipeline owns', () async {
          final rgba = freshPixels();
          final provider = RawPixelsImage(payloadOf(rgba));
          await resolveOnce(provider);
          PaintingBinding.instance.imageCache.clearLiveImages();
          PaintingBinding.instance.imageCache.evict(provider);

          expect(PaintingBinding.instance.imageCache.currentSize, 0);
          // The payload -- the pipeline's actual retained state -- is untouched by
          // an ImageCache eviction. This is the whole I5 dissolution: eviction can
          // never destroy something the pipeline still needs, because what the
          // pipeline retains is bytes, not a handle.
          expect(rgba.lengthInBytes, 2 * 2 * 4);
          final again = await resolveOnce(RawPixelsImage(payloadOf(rgba)));
          expect(again.width, 2, reason: 'rebuildable from the retained bytes '
              'alone -- no native call, no ownership contract');
        });
      });

  });
}

// --- top-level helpers from dng_decoder_smoke_test.dart (trailing) ---
/// Resolves the vendored dylib via `.dart_tool/package_config.json`, without
/// hardcoding a dev machine path.
///
/// 2026-08-21 (D1): this used to point at the `app` package's CMake build tree
/// (`native/build/`), which only exists on a machine that has built the native
/// target. It now points at the copy `ceyx` vendors into host app
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
        (p) => p['name'] == 'ceyx',
        orElse: () => throw StateError(
          'ceyx not found in package_config.json; '
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
