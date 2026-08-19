import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';

/// Feedback for a finished batch delete.
///
/// Failures win: they get a blocking dialog, because a delete that silently
/// did nothing is indistinguishable from a broken app. Recycle success goes to
/// the transient status line (see `StatusLine`), reminding the user the files
/// are still on disk. Direct-delete success stays silent, as it always has.
void showBatchDeleteFeedback(BuildContext context, BatchDeleteResult result) {
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

  context.read<AppState>().showStatus(
    StatusMessage(
      '已回收 *${result.movedCount}* 個檔案到 .trash（未直接刪除，請自行清理）',
      revealPath: result.trashDirPath,
    ),
  );
}
