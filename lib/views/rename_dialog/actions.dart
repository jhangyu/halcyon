import 'package:flutter/material.dart';

import '../theme_tokens.dart';

/// Bottom action row of the rename dialog: file count / hint text plus
/// Cancel and Run Rename buttons.
class RenameActions extends StatelessWidget {
  const RenameActions({
    super.key,
    required this.itemCount,
    required this.error,
    required this.onCancel,
    required this.onRun,
  });

  final int itemCount;
  final String? error;
  final VoidCallback onCancel;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      child: Row(
        children: [
          Flexible(
            child: Text(
              '$itemCount files · non-writable folders cannot reach this dialog',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: t.textFaint),
            ),
          ),
          const SizedBox(width: 12),
          const Spacer(),
          TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(
              foregroundColor: t.text,
              backgroundColor: t.surface,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: BorderSide(color: t.border),
              ),
            ),
            child: const Text('Cancel', style: TextStyle(fontSize: 12.5)),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: error != null ? null : onRun,
            style: FilledButton.styleFrom(
              backgroundColor: t.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: const Text(
              'Run Rename',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
