import 'dart:io';

import 'package:flutter/material.dart';

import '../providers/app_state.dart';

/// Feedback for a finished batch delete.
///
/// Failures win: they get a blocking dialog, because a delete that silently
/// did nothing is indistinguishable from a broken app. Recycle success gets a
/// non-blocking 2.5s SnackBar reminding the user the files are still on disk.
/// Direct-delete success stays silent, as it always has.
void showBatchDeleteFeedback(
  BuildContext context,
  BatchDeleteResult result, {
  void Function(String path)? revealInFinder,
}) {
  if (result.failures.isNotEmpty) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('部分檔案未能處理'),
        content: SingleChildScrollView(
          child: Text(result.failures.join('\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
    return;
  }

  if (!result.recycled) return;

  final trashDirPath = result.trashDirPath;
  final reveal = revealInFinder ?? _openInFinder;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(milliseconds: 2500),
      content: Text('已回收 ${result.movedCount} 個檔案到 .trash（未直接刪除，請自行清理）'),
      action: trashDirPath == null
          ? null
          : SnackBarAction(label: '顯示', onPressed: () => reveal(trashDirPath)),
    ),
  );
}

// macOS-only app; `open` on a directory reveals it in Finder.
void _openInFinder(String path) {
  Process.run('open', [path]);
}
