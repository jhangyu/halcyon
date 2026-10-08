// Clean mouse click → next/previous photo over the photo viewport.
// Behaviour: mousenav-spec.md §4 (docs/logs/2026-10-08).
// `kMouseNavClickSlop` is the calibration knob (spec §1.3).
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../providers/app_settings.dart';
import '../../../providers/app_state.dart';

/// Max distance (logical px) the pointer may travel during a press and
/// still count as a click.
const double kMouseNavClickSlop = 4.0;

enum MouseNavAction { next, previous }

/// The single decision point for a finished press; null = not a clean click.
MouseNavAction? resolveClick({
  required PointerDeviceKind kind,
  required int downButtons,
  required double maxTravel,
  required Duration pressDuration,
  required bool releasedInside,
  required MouseNavMapping mapping,
}) {
  if (kind != PointerDeviceKind.mouse) return null;
  if (downButtons != kPrimaryButton && downButtons != kSecondaryButton) {
    return null;
  }
  if (maxTravel > kMouseNavClickSlop) return null;
  if (pressDuration >= kLongPressTimeout) return null;
  if (!releasedInside) return null;
  final primary = downButtons == kPrimaryButton;
  return primary == (mapping == MouseNavMapping.leftNext)
      ? MouseNavAction.next
      : MouseNavAction.previous;
}

/// Wraps the photo area; a clean click calls [AppState.nextPhoto] or
/// [AppState.previousPhoto]. A `Listener`, so it never joins the gesture
/// arena and never takes focus (spec §1.6).
class MouseClickNav extends StatefulWidget {
  const MouseClickNav({super.key, required this.child});
  final Widget child;

  @override
  State<MouseClickNav> createState() => _MouseClickNavState();
}

class _MouseClickNavState extends State<MouseClickNav> {
  int? _pointer; // the tracked press; null = not tracking
  Offset _downPos = Offset.zero;
  Duration _downTime = Duration.zero;
  int _buttons = 0;
  PointerDeviceKind _kind = PointerDeviceKind.mouse;
  MouseNavMapping _mapping = MouseNavMapping.leftNext;
  double _maxTravel = 0;

  void _onDown(PointerDownEvent e) {
    if (_pointer != null) {
      _pointer = null; // second pointer: abort both
      return;
    }
    final state = context.read<AppState>();
    if (!state.mouseNavEnabled) return; // read at down time only
    _pointer = e.pointer;
    _downPos = e.position; // global = screen px at any zoom
    _downTime = e.timeStamp;
    _buttons = e.buttons;
    _kind = e.kind;
    _mapping = state.mouseNavMapping;
    _maxTravel = 0;
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    if (e.buttons != _buttons) {
      _pointer = null; // button set changed
      return;
    }
    _maxTravel = math.max(_maxTravel, (e.position - _downPos).distance);
  }

  void _onCancel(PointerCancelEvent e) {
    if (e.pointer == _pointer) _pointer = null;
  }

  void _onUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final size = context.size;
    final action = resolveClick(
      kind: _kind,
      downButtons: _buttons, // PointerUpEvent.buttons is 0
      maxTravel: math.max(_maxTravel, (e.position - _downPos).distance),
      pressDuration: e.timeStamp - _downTime,
      releasedInside:
          size != null && (Offset.zero & size).contains(e.localPosition),
      mapping: _mapping,
    );
    final state = context.read<AppState>();
    switch (action) {
      case MouseNavAction.next:
        state.nextPhoto();
      case MouseNavAction.previous:
        state.previousPhoto();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.opaque, // letterbox margins hit-test (spec §4.1)
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        child: widget.child,
      );
}
