import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/photo_payload.dart';
import 'package:halcyon_flutter/services/photo_payload_cache.dart';

void main() {
  // Both kinds at exactly the same byteCost, so any difference in how the
  // cache treats them is a difference in KIND, never in size.
  const side = 64;
  const cost = side * side * 4; // 16384 bytes

  EncodedPayload encoded() => EncodedPayload(Uint8List(cost));
  PixelPayload pixels() =>
      PixelPayload(rgba: Uint8List(cost), width: side, height: side);

  group('PhotoPayloadCache (D4: retention is type-blind)', () {
    // THE KILLER for D4. Everything else in this file is scaffolding.
    //
    // Runs the identical insert/evict scenario twice -- once with the pixel
    // payloads in even slots, once with them in odd slots -- and requires the
    // surviving ID SET to be identical. Any rule that consults the payload
    // kind (evict pixels first, exempt encoded bytes, weight one kind
    // differently) makes the two runs disagree, because the kinds sit at
    // different ids. A rule that reads only byteCost cannot tell the two runs
    // apart.
    test(
      'TC-060 eviction order is identical when the payload KINDS are swapped',
      () {
        List<String> survivorsWithPixelsAt(bool Function(int index) isPixel) {
          // Budget for 4 entries; 6 inserted, so 2 must go.
          final cache = PhotoPayloadCache(byteBudget: cost * 4);
          for (var i = 0; i < 6; i++) {
            cache.put('id$i', isPixel(i) ? pixels() : encoded());
          }
          return cache.ids.toList();
        }

        final pixelsEven = survivorsWithPixelsAt((i) => i.isEven);
        final pixelsOdd = survivorsWithPixelsAt((i) => i.isOdd);
        final allEncoded = survivorsWithPixelsAt((i) => false);

        expect(
          pixelsEven,
          allEncoded,
          reason:
              'putting pixel payloads in the even slots changed who survived '
              '-- the eviction rule is reading the payload kind, not byteCost',
        );
        expect(
          pixelsOdd,
          allEncoded,
          reason:
              'putting pixel payloads in the odd slots changed who survived '
              '-- the eviction rule is reading the payload kind, not byteCost',
        );
        // Sanity: the scenario really did evict something, so the assertions
        // above are not comparing three copies of "nothing happened".
        expect(allEncoded, ['id2', 'id3', 'id4', 'id5']);
      },
    );

    test('TC-061 the least recently USED entry is evicted, not the oldest '
        'inserted', () {
      final cache = PhotoPayloadCache(byteBudget: cost * 3);
      cache.put('a', encoded());
      cache.put('b', pixels());
      cache.put('c', encoded());
      // Touch 'a' so 'b' becomes the least recently used.
      expect(cache['a'], isNotNull);
      cache.put('d', pixels());

      expect(cache.contains('b'), isFalse, reason: 'b was the LRU entry');
      expect(cache.contains('a'), isTrue, reason: 'a was re-used before d');
      expect(cache.ids.toList(), ['c', 'a', 'd']);
    });

    test('TC-062 peek does not count as a use', () {
      final cache = PhotoPayloadCache(byteBudget: cost * 2);
      cache.put('a', encoded());
      cache.put('b', encoded());
      expect(cache.peek('a'), isNotNull);
      cache.put('c', encoded());
      expect(
        cache.contains('a'),
        isFalse,
        reason: 'peek must be observation-only, or bookkeeping reads would '
            'silently reorder eviction',
      );
    });

    test('TC-063 a payload larger than the whole budget is still retained', () {
      final cache = PhotoPayloadCache(byteBudget: cost);
      cache.put('huge', PixelPayload(
        rgba: Uint8List(cost * 4),
        width: side * 2,
        height: side * 2,
      ));
      expect(
        cache.peek('huge'),
        isNotNull,
        reason: 'writing a payload and evicting it in the same breath strands '
            'the view on a spinner that can never resolve',
      );
    });

    test('TC-064 retainOnly drops exactly the ids outside the window and '
        'reports them', () {
      final cache = PhotoPayloadCache();
      for (var i = 0; i < 5; i++) {
        cache.put('id$i', i.isEven ? encoded() : pixels());
      }
      final dropped = cache.retainOnly({'id1', 'id3'});
      expect(dropped..sort(), ['id0', 'id2', 'id4']);
      expect(cache.ids.toList(), ['id1', 'id3']);
      expect(cache.totalByteCost, cost * 2);
    });

    test('TC-065 the retention window is -3..+5, clamped at both ends', () {
      final items = List.generate(20, (i) => 'id$i');
      String idOf(String s) => s;

      expect(
        retentionWindowIds(items, 8, idOf),
        {for (var i = 5; i <= 13; i++) 'id$i'},
        reason: '-3..+5 around index 8',
      );
      expect(retentionWindowIds(items, 0, idOf), {
        for (var i = 0; i <= 5; i++) 'id$i',
      });
      expect(retentionWindowIds(items, 19, idOf), {
        for (var i = 16; i <= 19; i++) 'id$i',
      });
      expect(retentionWindowIds(<String>[], 0, idOf), isEmpty);
    });
  });
}
