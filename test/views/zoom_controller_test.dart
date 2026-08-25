import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/views/zoom_controller.dart';

/// Plain `test()` only -- no `testWidgets`. These assertions need no widget
/// tree, and this repo has been bitten by FakeAsync hangs when real async work
/// runs inside a `testWidgets` body (memory.md / flutter-popupmenu-fakeasync).
///
/// The controller is instantiated directly here, which is also the proof that
/// it is constructible without `AppState` (contract AC5).
void main() {
  late ZoomController zoom;

  setUp(() {
    zoom = ZoomController();
  });

  tearDown(() {
    zoom.dispose();
  });

  /// Applies [n] zoom-in steps, feeding each animation target straight back
  /// into the transform controller -- i.e. simulating the animation having
  /// completed, which is what the detail view does over 200ms.
  void stepInAndSettle(int n) {
    for (var i = 0; i < n; i++) {
      zoom.stepZoomIn();
      if (zoom.targetMatrix != null) {
        zoom.transformCtrl.value = zoom.targetMatrix!;
        zoom.shouldAnimateZoom = false;
      }
    }
  }

  double scaleOf(Matrix4 m) => m.getMaxScaleOnAxis();

  group('ordinary zoom request', () {
    // Without this, mutant M6 (deleting `shouldAnimateZoom = true` from the
    // NON-reset branch of _zoomBy) left the whole suite green: the ceiling
    // test asserts the flag is false and the reset test asserts the flag set
    // by the OTHER branch, so nothing observed the plain zoom path. In the
    // app that mutant means ordinary zoom in/out never animates at all and
    // only the <=1.05 reset still works.
    test('a plain zoom-in from identity requests an animation', () {
      zoom.pointerPosition = null;
      zoom.lastKnownCenter = const Offset(400, 300);

      zoom.stepZoomIn();

      expect(zoom.shouldAnimateZoom, isTrue);
      expect(zoom.targetMatrix, isNotNull);
      expect(zoom.targetMatrix, isNot(equals(Matrix4.identity())));
      expect(scaleOf(zoom.targetMatrix!), closeTo(1.25, 1e-9));
    });

    test('a plain zoom-out from a zoomed-in state requests an animation', () {
      // 1.25^3 = 1.953 -> one step out lands at 1.5625, i.e. still on the
      // non-reset branch, so this too only passes if that branch sets the
      // flag.
      stepInAndSettle(3);
      zoom.shouldAnimateZoom = false;

      zoom.stepZoomOut();

      expect(zoom.shouldAnimateZoom, isTrue);
      expect(zoom.targetMatrix, isNot(equals(Matrix4.identity())));
    });
  });

  group('upper bound', () {
    test('zooming in repeatedly clamps at exactly 5.0x', () {
      // 1.25^8 == 5.96 -- without a clamp this overshoots the limit.
      stepInAndSettle(8);
      expect(scaleOf(zoom.transformCtrl.value), closeTo(5.0, 1e-9));
    });

    test('a step at the 5.0x ceiling produces no further zoom request', () {
      stepInAndSettle(8);
      expect(scaleOf(zoom.transformCtrl.value), closeTo(5.0, 1e-9));

      zoom.shouldAnimateZoom = false;
      zoom.stepZoomIn();

      // scaleFactor collapses to 1.0 at the ceiling, so _zoomBy bails out
      // without requesting an animation.
      expect(zoom.shouldAnimateZoom, isFalse);
    });
  });

  group('lower bound reset', () {
    test('a target scale <= 1.05 snaps back to identity, not to 1.0x-ish', () {
      // 1.25 zoomed out by one step lands on 1.0 (<= 1.05) -> reset.
      // The focal point is deliberately MOVED between the two steps: without
      // the reset branch, zooming back out about a different point returns to
      // scale 1.0 but with a leftover translation, which is exactly the
      // boundary drift the reset exists to prevent. Zooming out about the
      // SAME point would land on identity either way and would therefore not
      // discriminate.
      zoom.pointerPosition = const Offset(100, 100);
      stepInAndSettle(1);
      expect(scaleOf(zoom.transformCtrl.value), closeTo(1.25, 1e-9));
      zoom.pointerPosition = const Offset(700, 500);

      zoom.stepZoomOut();

      expect(zoom.shouldAnimateZoom, isTrue);
      expect(zoom.targetMatrix, isNotNull);
      expect(zoom.targetMatrix, equals(Matrix4.identity()));
      // The point of the reset: no leftover translation drift.
      final t = zoom.targetMatrix!.getTranslation();
      expect(t.x, 0.0);
      expect(t.y, 0.0);
    });

    test('a scale still above 1.05 after zoom-out is NOT reset to identity',
        () {
      // 1.25^3 = 1.953; one step out -> 1.5625, still above the threshold.
      stepInAndSettle(3);

      zoom.stepZoomOut();

      expect(zoom.targetMatrix, isNotNull);
      expect(zoom.targetMatrix, isNot(equals(Matrix4.identity())));
      expect(scaleOf(zoom.targetMatrix!), closeTo(1.5625, 1e-9));
    });
  });

  group('focus selection', () {
    /// The focal point is recoverable from the produced matrix: zooming about
    /// a point leaves that point fixed, so `m * focal == focal`.
    Offset fixedPointOf(Matrix4 m) {
      final t = m.getTranslation();
      final s = m.getMaxScaleOnAxis();
      return Offset(t.x / (1 - s), t.y / (1 - s));
    }

    test('uses pointerPosition when the cursor is over the viewer', () {
      zoom.lastKnownCenter = const Offset(400, 300);
      zoom.pointerPosition = const Offset(120, 80);

      zoom.stepZoomIn();

      final focal = fixedPointOf(zoom.targetMatrix!);
      expect(focal.dx, closeTo(120, 1e-6));
      expect(focal.dy, closeTo(80, 1e-6));
    });

    test('falls back to lastKnownCenter when the cursor has left', () {
      zoom.lastKnownCenter = const Offset(640, 360);
      zoom.pointerPosition = null;

      zoom.stepZoomIn();

      final focal = fixedPointOf(zoom.targetMatrix!);
      expect(focal.dx, closeTo(640, 1e-6));
      expect(focal.dy, closeTo(360, 1e-6));
    });

    test('a later layout centre is used once the pointer exits', () {
      zoom.pointerPosition = const Offset(10, 10);
      zoom.lastKnownCenter = const Offset(500, 250);
      zoom.pointerPosition = null;

      zoom.stepZoomIn();

      final focal = fixedPointOf(zoom.targetMatrix!);
      expect(focal.dx, closeTo(500, 1e-6));
      expect(focal.dy, closeTo(250, 1e-6));
    });
  });

  group('notification contract', () {
    test('a zoom request notifies listeners exactly once', () {
      var notifications = 0;
      zoom.addListener(() => notifications++);

      zoom.stepZoomIn();

      expect(notifications, 1);
    });

    test('writing lastKnownCenter or pointerPosition never notifies', () {
      var notifications = 0;
      zoom.addListener(() => notifications++);

      // lastKnownCenter is written from inside a LayoutBuilder builder; a
      // notification there is an infinite rebuild.
      zoom.lastKnownCenter = const Offset(1, 2);
      zoom.pointerPosition = const Offset(3, 4);
      zoom.pointerPosition = null;

      expect(notifications, 0);
    });
  });
}
