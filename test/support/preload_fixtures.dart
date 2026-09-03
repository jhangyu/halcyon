import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';

/// Shared fixtures for the image-pipeline tests.
///
/// Extracted 2026-09-03 (ROI refactor T2) from the byte-identical copies that
/// had accumulated in 18 test files. Nothing here changes behaviour: the poll
/// interval, the 5s deadline, the PNG bytes and the generated ids/paths are the
/// ones the call sites already used.
///
/// [until] is deliberately a REAL-async poll. It must never be wrapped in
/// FakeAsync (G-020/G-021): the pipeline crosses real engine futures, which a
/// fake clock never flushes, and `flutter test --timeout` does not rescue a
/// fake-async deadlock — the run hangs at near-zero CPU forever.
/// Polls until [condition] holds, failing at a 5-second deadline.
///
/// The pipeline crosses a 250ms debounce plus two real engine futures, so there
/// is no single future to await; a fixed sleep would be either flaky or slow.
///
/// [pollInterval] defaults to the 10ms most call sites used; the two 5ms call
/// sites pass their own value so their timing is unchanged.
Future<void> until(
  bool Function() condition, {
  String? reason,
  Duration pollInterval = const Duration(milliseconds: 10),
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(pollInterval);
  }
}

/// A minimal valid 1x1 transparent PNG: exercises a REAL engine decode without
/// shipping a binary fixture file.
final Uint8List tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// A fresh encoded payload holding its OWN bytes object, so two payloads never
/// collide on the MemoryImage cache key (which is bytes identity + scale).
EncodedPayload freshEncodedPayload() =>
    EncodedPayload(Uint8List.fromList(tinyPngBytes));

/// A 1x1 fully transparent decoded image, for the full-res publish paths.
Future<ui.Image> tinyImage() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List(4),
    1,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// `count` items with id `<idPrefix><i>` and file `<dir>/<idPrefix><i>.<extension>`.
///
/// The defaults reproduce the `p0../x/p0.jpg` shape; call sites that used
/// `a$i`/`/tmp` or `.arw` pass those explicitly. Every existing call site's
/// strings are reproduced exactly — no call site's ids or paths change.
List<PhotoItem> photoItems(
  int count, {
  String idPrefix = 'p',
  String dir = '/x',
  String extension = 'jpg',
}) => <PhotoItem>[
  for (var i = 0; i < count; i++)
    PhotoItem(
      id: '$idPrefix$i',
      files: <File>[File('$dir/$idPrefix$i.$extension')],
    ),
];

/// `count` items with the zero-padded `IMG_0000` id shape under `/tmp`.
List<PhotoItem> paddedItems(int count, {String extension = 'jpg'}) =>
    List<PhotoItem>.generate(count, (index) {
      final id = 'IMG_${index.toString().padLeft(4, '0')}';
      return PhotoItem(id: id, files: <File>[File('/tmp/$id.$extension')]);
    });

/// The shared `setUp` body: a live ImageCache entry from a previous test is a
/// cross-test dependency, and these tests assert on cache membership.
void clearImageCacheSetUp() {
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
}
