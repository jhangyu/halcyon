/// The ONE EXIF Orientation table in this codebase.
///
/// It used to exist twice: once in `thumbnail_export_service.dart` as
/// `package:image` operations, once in `decoded_rgba_image_provider.dart` as
/// a quarter-turn + mirror pair for `dart:ui`. Two hand-written 8-case
/// switches that must agree forever is a drift bug waiting to happen, so both
/// now derive from this data.
///
/// [quarterTurnsCw] is applied FIRST, then [mirrored] flips horizontally.
///
/// EXIF Orientation semantics (all 8 spelled out -- do not special-case only
/// the common values):
///  1 = normal (identity)
///  2 = flip horizontal
///  3 = rotate 180
///  4 = flip vertical (= rotate 180 then flip horizontal)
///  5 = transpose (rotate 90 CW then flip horizontal)
///  6 = rotate 90 CW
///  7 = transverse (rotate 270 CW then flip horizontal)
///  8 = rotate 270 CW
typedef ExifTransform = ({int quarterTurnsCw, bool mirrored});

ExifTransform exifTransformFor(int orientation) {
  return switch (orientation) {
    2 => (quarterTurnsCw: 0, mirrored: true),
    3 => (quarterTurnsCw: 2, mirrored: false),
    4 => (quarterTurnsCw: 2, mirrored: true),
    5 => (quarterTurnsCw: 1, mirrored: true),
    6 => (quarterTurnsCw: 1, mirrored: false),
    7 => (quarterTurnsCw: 3, mirrored: true),
    8 => (quarterTurnsCw: 3, mirrored: false),
    // 1, and anything unrecognised: an unknown tag is not a reason to refuse
    // to show the photo.
    _ => (quarterTurnsCw: 0, mirrored: false),
  };
}
