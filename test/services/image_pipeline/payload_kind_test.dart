// Task 1 (compressed-residency v2): the per-kind payload capture instrument.
//
// Why these three cases: `docs/logs/2026-09-11/memory-attribution-table.md:3`
// records that the per-kind split is NOT part of the agreed
// `MemoryLedgerSnapshot` schema, and that the artifact's
// "of which PixelPayload | 0 | 0" row is therefore not evidence of absence.
// AC-1 of spec v2 is exactly a per-kind claim, so the instrument has to exist
// before the claim can be made -- and it has to be proven able to report a
// NON-ZERO number, which is what the third case does (a schema field added
// without a wired consumer reports 0 forever and looks like a pass).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload_cache.dart';

import '../../support/preload_fixtures.dart';

Future<NativeImageResult> _needsRawDecodeLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

DecodedRgba _decodedFixture() {
  final rgba = Uint8List(4 * 4 * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  return DecodedRgba(rgba: rgba, width: 4, height: 4);
}

List<PhotoItem> _rawItems(List<String> ids) => [
  for (final id in ids) PhotoItem(id: id, files: [File('/tmp/$id.dng')]),
];

void main() {
  late ImageCache imageCache;
  late int originalMaximumSizeBytes;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    imageCache = PaintingBinding.instance.imageCache;
    originalMaximumSizeBytes = imageCache.maximumSizeBytes;
    // `main()` never runs under `flutter test`, so this would otherwise be the
    // 100 MiB Flutter default rather than the app's configured budget. Pinned
    // explicitly because this file asserts residency.
    imageCache.maximumSizeBytes = 256 << 20;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDown(() {
    imageCache.maximumSizeBytes = originalMaximumSizeBytes;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  group('payload_kind_test.dart', () {
    test(
      'TC-A1 a cache holding one payload of each kind reports the per-kind '
      'split and a total that still equals the sum',
      () {
        final cache = PhotoPayloadCache();
        final encoded = EncodedPayload(Uint8List(11));
        final pixels = PixelPayload(
          rgba: Uint8List(2 * 3 * 4),
          width: 2,
          height: 3,
        );
        cache.put('encoded', encoded);
        cache.put('pixels', pixels);

        expect(encoded.kind, PayloadKind.encoded);
        expect(pixels.kind, PayloadKind.pixels);
        expect(cache.pixelEntryCount, 1);
        expect(cache.pixelByteTotal, pixels.byteCost);
        expect(cache.encodedByteTotal, encoded.byteCost);
        expect(cache.totalByteCost, encoded.byteCost + pixels.byteCost);
      },
    );

    test(
      'TC-A2 an EMPTY cache reports 0/0/0 from all three getters without '
      'throwing (the empty-map trap setByteBudget documents)',
      () {
        final cache = PhotoPayloadCache();
        expect(cache.pixelEntryCount, 0);
        expect(cache.pixelByteTotal, 0);
        expect(cache.encodedByteTotal, 0);
        expect(cache.totalByteCost, 0);
      },
    );

    test(
      'TC-A3 a MemoryLedgerSnapshot taken from a controller retaining one '
      'payload of each kind reports BOTH per-kind byte totals non-zero -- the '
      '"field present, always 0" failure mode is what this pins',
      () async {
        // Item `a` encodes successfully; item `b`'s encode throws, so its slot
        // falls back to pixels. The decoder deliberately throws on any SECOND
        // decode of the same path, so the deferred re-encode path added in
        // Tasks 3/4 abandons for `b` and this assertion stays a fixed point
        // for the whole round instead of racing a later replacement.
        final decodeCounts = <String, int>{};
        var encodeCalls = 0;
        final controller = ImagePreloadController(
          imageLoader: _needsRawDecodeLoader,
          dngDecoder: (path) async {
            final n = (decodeCounts[path] ?? 0) + 1;
            decodeCounts[path] = n;
            if (n > 1) throw StateError('second decode of $path refused');
            return _decodedFixture();
          },
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async {
            encodeCalls++;
            if (encodeCalls == 1) throw StateError('encode refused');
            return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
          },
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        // `b` first, so it is the item whose encode is call #1.
        unawaited(
          controller.preloadImages(
            items: _rawItems(['b', 'a']),
            selectedItemId: 'b',
            notifyLoaded: () {},
          ),
        );
        await until(
          () =>
              controller.debugMemoryLedgerSnapshot.payloadCachePixelByteTotal >
                  0 &&
              controller
                      .debugMemoryLedgerSnapshot
                      .payloadCacheEncodedByteTotal >
                  0,
          reason: 'both payload kinds are retained at once',
        );

        final snapshot = controller.debugMemoryLedgerSnapshot;
        expect(snapshot.payloadCachePixelEntryCount, 1);
        expect(snapshot.payloadCachePixelByteTotal, greaterThan(0));
        expect(snapshot.payloadCacheEncodedByteTotal, greaterThan(0));
        // The new fields must not have been wired to the same source: their
        // sum is the whole retained total, nothing double-counted.
        expect(
          snapshot.payloadCachePixelByteTotal +
              snapshot.payloadCacheEncodedByteTotal,
          snapshot.retainedPayloadBytes,
        );
        expect(snapshot.toString(), contains('payloadCachePixelEntryCount'));
      },
    );
  });
}
