// Plain test(), never testWidgets(): decoding awaits a real engine future
// (ui.decodeImageFromPixels), which hangs forever inside testWidgets'
// FakeAsync zone.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/raw_pixels_image.dart';

import '../../support/preload_fixtures.dart';

void main() {
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
}
