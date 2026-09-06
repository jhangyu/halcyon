/// The ONE EXIF Orientation table in this codebase.
///
/// It used to exist twice: once in `photo_export_service.dart` as
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

/// The orientation still to be applied by the host, given that the decoder
/// already applied [applied] and the file's IFD0 tag declares [declared].
///
/// Total: defined for every `int` pair (including values outside 1..8 --
/// [exifTransformFor] already treats those as identity), never asserts,
/// never throws. Three cases:
///  * `applied == declared` -> 1 (the normal native-rotation case: nothing
///    left to do).
///  * `applied == 1` -> `declared` (today's behaviour: the decoder applied
///    nothing, so the host must apply everything).
///  * anything else -> the actual composite, computed by treating each of
///    the two `(quarterTurnsCw, mirrored)` pairs as an element of the
///    dihedral group D4 (the group of symmetries of a rectangle) and
///    looking the composite `declared ∘ applied⁻¹` back up in this file's
///    8-case table.
///
/// This is the mechanism that makes multi-arm decoder dispatch safe: a
/// decoder that ignores the orientation request, a build whose dylib
/// predates native orientation, and the pure-Dart TIFF arm are all correct
/// without a feature flag, because they all report `applied == 1` and this
/// function falls back to "apply the full declared orientation".
int residualExifOrientation({required int declared, required int applied}) {
  if (applied == declared) return 1;
  if (applied == 1) return declared;

  final declaredMatrix = _matrixFor(exifTransformFor(declared));
  final appliedMatrix = _matrixFor(exifTransformFor(applied));
  // Every matrix produced by _matrixFor is orthogonal (rows/columns are
  // unit vectors, entries in {-1,0,1}), so its inverse is its transpose.
  final appliedInverse = _transpose(appliedMatrix);
  final residualMatrix = _matMul(declaredMatrix, appliedInverse);

  for (var quarterTurnsCw = 0; quarterTurnsCw < 4; quarterTurnsCw++) {
    for (final mirrored in const [false, true]) {
      final candidate = _matrixFor((
        quarterTurnsCw: quarterTurnsCw,
        mirrored: mirrored,
      ));
      if (_matEq(candidate, residualMatrix)) {
        return _orientationFor(quarterTurnsCw, mirrored);
      }
    }
  }
  // Unreachable: the 8 (quarterTurnsCw, mirrored) pairs above enumerate all
  // of D4, which is closed under the composition above. Kept as a defined
  // total fallback rather than an assertion per this function's contract.
  return 1;
}

/// A 2x2 integer matrix, row-major: `[[a,b],[c,d]]`.
typedef _Mat2 = List<List<int>>;

_Mat2 _rotationMatrix(int quarterTurnsCw) {
  return switch (quarterTurnsCw % 4) {
    1 => [
      [0, -1],
      [1, 0],
    ],
    2 => [
      [-1, 0],
      [0, -1],
    ],
    3 => [
      [0, 1],
      [-1, 0],
    ],
    _ => [
      [1, 0],
      [0, 1],
    ],
  };
}

const _Mat2 _horizontalMirrorMatrix = [
  [-1, 0],
  [0, 1],
];

/// The linear part of applying [transform]: rotate first, then mirror --
/// matching this file's dartdoc ("[quarterTurnsCw] is applied FIRST, then
/// [mirrored] flips horizontally").
_Mat2 _matrixFor(ExifTransform transform) {
  final rotation = _rotationMatrix(transform.quarterTurnsCw);
  return transform.mirrored ? _matMul(_horizontalMirrorMatrix, rotation) : rotation;
}

_Mat2 _matMul(_Mat2 a, _Mat2 b) {
  return [
    [
      a[0][0] * b[0][0] + a[0][1] * b[1][0],
      a[0][0] * b[0][1] + a[0][1] * b[1][1],
    ],
    [
      a[1][0] * b[0][0] + a[1][1] * b[1][0],
      a[1][0] * b[0][1] + a[1][1] * b[1][1],
    ],
  ];
}

_Mat2 _transpose(_Mat2 a) => [
  [a[0][0], a[1][0]],
  [a[0][1], a[1][1]],
];

bool _matEq(_Mat2 a, _Mat2 b) =>
    a[0][0] == b[0][0] && a[0][1] == b[0][1] && a[1][0] == b[1][0] && a[1][1] == b[1][1];

int _orientationFor(int quarterTurnsCw, bool mirrored) {
  for (var n = 1; n <= 8; n++) {
    final t = exifTransformFor(n);
    if (t.quarterTurnsCw == quarterTurnsCw && t.mirrored == mirrored) return n;
  }
  return 1;
}
