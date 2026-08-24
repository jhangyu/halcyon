import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/exif_orientation.dart';

void main() {
  test('TC-213 exifTransformFor maps all eight EXIF values', () {
    expect(exifTransformFor(1), (quarterTurnsCw: 0, mirrored: false));
    expect(exifTransformFor(2), (quarterTurnsCw: 0, mirrored: true));
    expect(exifTransformFor(3), (quarterTurnsCw: 2, mirrored: false));
    expect(exifTransformFor(4), (quarterTurnsCw: 2, mirrored: true));
    expect(exifTransformFor(5), (quarterTurnsCw: 1, mirrored: true));
    expect(exifTransformFor(6), (quarterTurnsCw: 1, mirrored: false));
    expect(exifTransformFor(7), (quarterTurnsCw: 3, mirrored: true));
    expect(exifTransformFor(8), (quarterTurnsCw: 3, mirrored: false));
  });

  test('TC-213b an unrecognised orientation is identity, not a guess', () {
    expect(exifTransformFor(0), (quarterTurnsCw: 0, mirrored: false));
    expect(exifTransformFor(9), (quarterTurnsCw: 0, mirrored: false));
    expect(exifTransformFor(-1), (quarterTurnsCw: 0, mirrored: false));
  });
}
