import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';

/// Bottom-of-window transient status line, replacing SnackBar.
///
/// SnackBar was swapped out for two reasons: its fade-out is hardcoded to
/// 250ms (the design calls for 500ms), and its default M3 colours sat too
/// close to the app's own surfaces. Timing here is explicit: 2.5s at full
/// opacity, 0.5s fade, gone at 3.0s.
///
/// Colours are inverse-contrast (variant B): a light bar in dark mode, a dark
/// bar in light mode, with an amber emphasis span (variant A's accent) whose
/// shade flips with the bar so it stays readable either way.
class StatusLine extends StatefulWidget {
  const StatusLine({super.key, this.revealInFinder});

  /// Injection point for tests; defaults to [revealInFileManager].
  final Future<String?> Function(String path)? revealInFinder;

  static const visibleDuration = Duration(milliseconds: 2500);
  static const fadeDuration = Duration(milliseconds: 500);

  @override
  State<StatusLine> createState() => _StatusLineState();
}

class _StatusLineState extends State<StatusLine> {
  int _seenSeq = 0;
  StatusMessage? _message;
  bool _visible = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _show(StatusMessage message) {
    _message = message;
    _visible = true;
    _timer?.cancel();
    _timer = Timer(StatusLine.visibleDuration, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.statusSeq != _seenSeq) {
      _seenSeq = state.statusSeq;
      final message = state.status;
      if (message != null) _show(message);
    }

    final message = _message;
    if (message == null) return const SizedBox.shrink();

    final dark = Theme.of(context).brightness == Brightness.dark;
    final barColor = dark ? const Color(0xFFECECEE) : const Color(0xFF26262A);
    final textColor = dark ? const Color(0xFF17171A) : Colors.white;
    final accentColor = dark
        ? const Color(0xFFA85D00) // amber dark enough to read on a light bar
        : const Color(0xFFFFD34D);

    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: StatusLine.fadeDuration,
        // Drop the widget once faded out so it can't swallow hit tests.
        onEnd: () {
          if (!_visible && mounted) setState(() => _message = null);
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 16, left: 24, right: 24),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: barColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(
                color: Color(0x4D000000),
                blurRadius: 20,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: emphasisSpans(message.text, accentColor),
                  ),
                  style: TextStyle(color: textColor, fontSize: 13),
                ),
              ),
              if (message.revealPath != null) ...[
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () async {
                    final reveal = widget.revealInFinder ?? revealInFileManager;
                    final path = message.revealPath!;
                    final capturedContext = context;
                    final failure = await reveal(path);
                    if (failure != null && capturedContext.mounted) {
                      capturedContext.read<AppState>().showStatus(
                            StatusMessage(failure),
                          );
                    }
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: accentColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('顯示'),
                ),
              ],
              if (message.actionLabel != null) ...[
                const SizedBox(width: 12),
                TextButton(
                  onPressed: message.onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: accentColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(message.actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Splits `a*b*c` into plain/emphasised runs; odd segments get [accent].
List<TextSpan> emphasisSpans(String text, Color accent) {
  final parts = text.split('*');
  return [
    for (var i = 0; i < parts.length; i++)
      if (parts[i].isNotEmpty)
        TextSpan(
          text: parts[i],
          style: i.isOdd
              ? TextStyle(color: accent, fontWeight: FontWeight.w600)
              : null,
        ),
  ];
}

/// M6 F-19. The single C-3 enumerated exception: per-platform commands via
/// Process.run, awaited, errors surfaced (the old fire-and-forget discarded
/// the Future AND the failure). Returns null on success, else a message for
/// the status line.
Future<String?> revealInFileManager(
  String path, {
  String? os,
  Future<ProcessResult> Function(String, List<String>)? runProcess,
}) async {
  final system = os ?? Platform.operatingSystem;
  final run = runProcess ?? (c, a) => Process.run(c, a);
  final isWindows = system == 'windows';
  final (cmd, args) = switch (system) {
    'macos' => ('open', ['-R', path]), // selects the file
    // Single-argument '/select,<path>' form (no space after the comma) is
    // the form that reliably selects the file in Explorer; trust-on-first-
    // use, no Windows host available here to verify against a real binary.
    'windows' => ('explorer', ['/select,$path']),
    _ => ('xdg-open', [File(path).parent.path]), // folder only (ruling)
  };
  try {
    final result = await run(cmd, args);
    // explorer.exe exits nonzero (commonly 1) even on success — a known
    // quirk, not a failure signal. Only a thrown ProcessException (binary
    // missing, spawn failure) counts as failure on Windows.
    if (isWindows) return null;
    return result.exitCode == 0
        ? null
        : 'Reveal failed: $cmd exited ${result.exitCode}';
  } on ProcessException catch (e) {
    return 'Reveal failed: ${e.message}';
  }
}
