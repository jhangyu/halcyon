import 'package:flutter/widgets.dart';

/// View-layer owner of all zoom/pan state for the detail viewer.
///
/// Zoom is pure screen state: it depends on the viewport geometry and the
/// pointer, never on the photo library. Keeping it here (instead of in
/// `AppState`) is what lets the detail view stop writing back into the data
/// layer — the keyboard entry point in `MainScreen` calls
/// [stepZoomIn]/[stepZoomOut] directly on this object.
///
/// Ownership: created and disposed by `_MainScreenState`, NOT by the photo
/// viewport widget. The viewport is rebuilt on photo switches, so a
/// controller owned by it would lose the zoom level every time the user
/// pressed left/right — zoom retention across photo switches is existing
/// behaviour that must survive (see gotcha G-010 and the related handover
/// notes).
///
/// Notification contract: [notifyListeners] fires ONLY from [_zoomBy], i.e.
/// only when a new animation target has been produced. [lastKnownCenter] and
/// [pointerPosition] are plain fields written during layout/hover and must
/// never notify — `lastKnownCenter` is written from inside a `LayoutBuilder`
/// builder, where a notification would mean an infinite rebuild.
class ZoomController extends ChangeNotifier {
  /// The matrix actually applied by `InteractiveViewer`. Its object identity
  /// must stay stable for the widget's whole lifetime, which is why this
  /// controller (not the widget) creates and disposes it.
  final TransformationController transformCtrl = TransformationController();

  /// Cursor position in viewer-local coordinates, or null when the pointer is
  /// outside the viewer. Written by `MouseRegion` onHover/onExit.
  Offset? pointerPosition;

  /// Centre of the viewer in its own coordinates, refreshed on every layout.
  /// The initial value is only a placeholder for the frames before the first
  /// layout has run.
  Offset lastKnownCenter = const Offset(400, 300);

  /// One-shot animation request: [targetMatrix] is where the viewer should
  /// animate to, [shouldAnimateZoom] says a fresh request is pending. The
  /// consumer (the detail view's zoom listener) is also the clearer.
  Matrix4? targetMatrix;
  bool shouldAnimateZoom = false;

  /// Maximum zoom; mirrors `InteractiveViewer.maxScale` in the detail view.
  static const double maxScale = 5.0;

  /// At or below this scale we snap all the way back to identity instead of
  /// settling just above 1.0x, which would leave a drifted translation.
  static const double resetScaleThreshold = 1.05;

  static const double _stepFactor = 1.25;

  void stepZoomIn() {
    _zoomBy(_stepFactor);
  }

  void stepZoomOut() {
    _zoomBy(1 / _stepFactor);
  }

  void _zoomBy(double scaleFactor) {
    double currentScale = transformCtrl.value.getMaxScaleOnAxis();
    double targetScale = currentScale * scaleFactor;

    // If we're hitting or going below 1.0x, snap perfectly back to the center avoiding boundary drifting
    if (targetScale <= resetScaleThreshold) {
      targetMatrix = Matrix4.identity();
      shouldAnimateZoom = true;
      notifyListeners();
      return;
    }

    if (targetScale > maxScale) {
      scaleFactor = maxScale / currentScale;
    }

    if (scaleFactor == 1.0) return;

    final focalPoint = pointerPosition ?? lastKnownCenter;

    // Translate to focal point, scale, and translate back
    final Matrix4 m = Matrix4.identity()
      ..translateByDouble(focalPoint.dx, focalPoint.dy, 0, 1)
      ..scaleByDouble(scaleFactor, scaleFactor, 1, 1)
      ..translateByDouble(-focalPoint.dx, -focalPoint.dy, 0, 1);

    targetMatrix = m.multiplied(transformCtrl.value);
    shouldAnimateZoom = true;
    notifyListeners();
  }

  @override
  void dispose() {
    transformCtrl.dispose();
    super.dispose();
  }
}
