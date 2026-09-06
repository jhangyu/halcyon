// Task 6 (native-rotation-spec.md): residual-orientation contract tests.
//
// AC-6.3 requires the 64-pair composition check to run against an
// INDEPENDENT oracle -- not a re-derivation of residualExifOrientation's own
// matrix algebra. The oracle below works a different way entirely: it
// simulates the actual pixel movement of a small labelled grid (rotate the
// list-of-lists, then mirror the rows), using only exifTransformFor (the
// normative table itself, per the spec) to decide how many quarter turns and
// whether to mirror. It never touches residualExifOrientation's matrix code.
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/exif_orientation.dart';

/// A small labelled grid: `grid[y][x]` is a unique pixel id.
typedef _Grid = List<List<int>>;

_Grid _rotate90Cw(_Grid m) {
  final h = m.length;
  final w = m[0].length;
  final result = List.generate(w, (_) => List<int>.filled(h, -1));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      result[x][h - 1 - y] = m[y][x];
    }
  }
  return result;
}

_Grid _mirrorHorizontal(_Grid m) => m.map((row) => row.reversed.toList()).toList();

_Grid _applyExifToGrid(_Grid base, int orientation) {
  final transform = exifTransformFor(orientation);
  var grid = base;
  for (var i = 0; i < transform.quarterTurnsCw; i++) {
    grid = _rotate90Cw(grid);
  }
  if (transform.mirrored) {
    grid = _mirrorHorizontal(grid);
  }
  return grid;
}

bool _gridEq(_Grid a, _Grid b) {
  if (a.length != b.length) return false;
  for (var y = 0; y < a.length; y++) {
    if (a[y].length != b[y].length) return false;
    for (var x = 0; x < a[y].length; x++) {
      if (a[y][x] != b[y][x]) return false;
    }
  }
  return true;
}

/// A 3x2 (width x height) base grid with a unique id per pixel, chosen
/// non-square and non-symmetric so rotate/mirror confusions are observable.
_Grid _baseGrid() => [
  [0, 1, 2],
  [3, 4, 5],
];

void main() {
  group('residualExifOrientation', () {
    test('AC-6.1: residual(n, n) == 1 for all n in 1..8', () {
      for (var n = 1; n <= 8; n++) {
        expect(
          residualExifOrientation(declared: n, applied: n),
          1,
          reason: 'declared == applied == $n should need nothing further',
        );
      }
    });

    test('AC-6.2: residual(n, 1) == n for all n in 1..8', () {
      for (var n = 1; n <= 8; n++) {
        expect(
          residualExifOrientation(declared: n, applied: 1),
          n,
          reason: 'decoder applied nothing, host must apply everything',
        );
      }
    });

    test(
      'AC-6.3: all 64 (declared, applied) pairs match an independent '
      'pixel-simulation oracle',
      () {
        final base = _baseGrid();
        for (var declared = 1; declared <= 8; declared++) {
          for (var applied = 1; applied <= 8; applied++) {
            final residual = residualExifOrientation(
              declared: declared,
              applied: applied,
            );

            final appliedGrid = _applyExifToGrid(base, applied);
            final resultGrid = _applyExifToGrid(appliedGrid, residual);
            final declaredGrid = _applyExifToGrid(base, declared);

            expect(
              _gridEq(resultGrid, declaredGrid),
              isTrue,
              reason:
                  'declared=$declared applied=$applied residual=$residual: '
                  'applying residual on top of the already-applied frame '
                  'must equal applying declared directly to the original',
            );
          }
        }
      },
    );

    test('is total for out-of-range ints (no throw, no assert)', () {
      expect(() => residualExifOrientation(declared: 0, applied: 0), returnsNormally);
      expect(() => residualExifOrientation(declared: -5, applied: 99), returnsNormally);
      expect(residualExifOrientation(declared: 0, applied: 0), 1);
    });
  });
}
