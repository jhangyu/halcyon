import 'package:flutter/foundation.dart';

/// A transient line shown at the bottom of the window (see `StatusLine`).
///
/// `*…*` in [text] marks the amber emphasis span. [revealPath], when set,
/// adds a "顯示" button that opens that path in Finder.
class StatusMessage {
  const StatusMessage(
    this.text, {
    this.revealPath,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final String? revealPath;

  /// Optional trailing button (e.g. "還原" after a rename batch).
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// A single [showStatus] emission, tagged with a monotonically increasing
/// [seq] so back-to-back `==`-equal [StatusMessage]s still produce distinct
/// [StatusEvent]s and are not coalesced by [ValueNotifier].
@immutable
class StatusEvent {
  const StatusEvent(this.seq, this.message);
  final int seq;
  final StatusMessage message;
}
